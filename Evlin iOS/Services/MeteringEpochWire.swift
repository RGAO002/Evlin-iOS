import Foundation

nonisolated struct MeteringAppleCallback: Codable, Equatable, Sendable {
    let activityName: String
    let eventName: String
    let observedAt: Date
}

nonisolated enum EpochRegistrationReasonDTO: String, Codable, Sendable {
    case initial
    case dayRollover = "day_rollover"
    case policyChange = "policy_change"
    case selectionChange = "selection_change"
    case enforcementSetChange = "enforcement_set_change"
    case identityRecovery = "identity_recovery"
    case gateResumeExactRebase = "gate_resume_exact_rebase"
    case gateResumeConservative = "gate_resume_conservative"
}

nonisolated enum EpochStatusDTO: String, Codable, Sendable { case active, paused, exhausted, retired }
nonisolated enum EpochRegistrationStatusDTO: String, Codable, Sendable { case registered, alreadyRegistered = "already_registered" }
nonisolated enum EpochActivationStatusDTO: String, Codable, Sendable { case activated, alreadyActivated = "already_activated", paused }
nonisolated enum MeteringSampleLane: String, Codable, Sendable { case v1, v2 }

nonisolated enum MeteringSampleWireAliases {
    static func activityName(routeID: UUID) -> String {
        "evlin.earned.budget.\(routeID.uuidString.lowercased())"
    }

    static func eventName(thresholdMinutes: Int) -> String {
        "evlin.earned.t\(thresholdMinutes)"
    }

    static func clientSampleID(
        lane: MeteringSampleLane,
        routeID: UUID,
        thresholdMinutes: Int
    ) -> String {
        "earned:\(lane.rawValue):\(routeID.uuidString.lowercased()):t\(thresholdMinutes)"
    }
}

nonisolated struct DeviceDaySnapshotDTO: Codable, Equatable, Sendable {
    let childDeviceID: UUID
    let usageDate: String
    let estimatedMinutes: Int
    let capMinutes: Int?
    let childDayState: String
    let usedMinutes: Int
    let remainingMinutes: Int
    let counted: Bool
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id", usageDate = "usage_date"
        case estimatedMinutes = "estimated_minutes", capMinutes = "cap_minutes"
        case childDayState = "child_day_state", usedMinutes = "used_minutes"
        case remainingMinutes = "remaining_minutes", counted, warning
    }
}

nonisolated struct EpochRegistrationRequestDTO: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let epochID: UUID
    let deviceID: UUID
    let usageDate: String
    let timezone: String
    let policyRevision: String
    let measurementSelectionDigest: String
    let enforcementSetID: UUID
    let startedAt: Date
    let baseAcceptedMinutes: Int
    let reason: EpochRegistrationReasonDTO

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", epochID = "epoch_id"
        case deviceID = "device_id", usageDate = "usage_date", timezone
        case policyRevision = "policy_revision"
        case measurementSelectionDigest = "measurement_selection_digest"
        case enforcementSetID = "enforcement_set_id", startedAt = "started_at"
        case baseAcceptedMinutes = "base_accepted_minutes", reason
    }
}

nonisolated struct EpochSampleRequestDTO: Codable, Equatable, Sendable {
    let deviceID: UUID
    let usageDate: String
    let timezone: String
    let activityName: String
    let eventName: String
    let thresholdMinutes: Int
    let estimatedMinutes: Int
    let observedAt: Date
    let clientSampleID: String
    let protocolVersion: Int?
    let epochID: UUID?
    let generationArmedAt: Date?
    let generationOffsetMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", usageDate = "usage_date", timezone
        case activityName = "activity_name", eventName = "event_name"
        case thresholdMinutes = "threshold_minutes", estimatedMinutes = "estimated_minutes"
        case observedAt = "observed_at", clientSampleID = "client_sample_id"
        case protocolVersion = "protocol_version", epochID = "epoch_id"
        case generationArmedAt = "generation_armed_at", generationOffsetMinutes = "generation_offset_minutes"
    }

    var lane: MeteringSampleLane? {
        let v2 = protocolVersion == 2 && epochID != nil && generationArmedAt == nil && generationOffsetMinutes == nil
        let v1MetadataValid = (generationArmedAt == nil && generationOffsetMinutes == nil) || (generationArmedAt != nil && generationOffsetMinutes != nil)
        let v1 = protocolVersion == nil && epochID == nil && v1MetadataValid
        return v2 ? .v2 : (v1 ? .v1 : nil)
    }
}

nonisolated struct EpochActivationRequestDTO: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let deviceID: UUID
    let routeID: UUID
    let verifiedAt: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", deviceID = "device_id"
        case routeID = "route_id", verifiedAt = "verified_at"
    }
}

nonisolated struct EpochRegistrationConflictDTO: Codable, Equatable, Sendable {
    let code: EpochRegistrationConflictCodeDTO
    let authoritativeSnapshot: DeviceDaySnapshotDTO

    enum CodingKeys: String, CodingKey {
        case code, authoritativeSnapshot = "authoritative_snapshot"
    }
}

nonisolated enum EpochRegistrationConflictCodeDTO: String, Codable, Sendable {
    case authoritativeBaseMismatch = "authoritative_base_mismatch"
}

nonisolated struct EpochRegistrationResponseDTO: Codable, Equatable, Sendable {
    let status: EpochRegistrationStatusDTO
    let epochID: UUID
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO
    let epochStatus: EpochStatusDTO?

    enum CodingKeys: String, CodingKey {
        case status, snapshot, epochID = "epoch_id"
        case meteringProtocolVersion = "metering_protocol_version"
        case epochStatus = "epoch_status"
    }
}

nonisolated struct EpochActivationResponseDTO: Codable, Equatable, Sendable {
    let status: EpochActivationStatusDTO
    let epochID: UUID
    let epochStatus: EpochStatusDTO
    let meteringProtocolVersion: Int
    let snapshot: DeviceDaySnapshotDTO

    enum CodingKeys: String, CodingKey {
        case status, snapshot, epochID = "epoch_id", epochStatus = "epoch_status"
        case meteringProtocolVersion = "metering_protocol_version"
    }
}

nonisolated enum MeteringEpochRequests {
    static func childState(baseURL: URL, ownerChildDeviceID: UUID) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("child/state"))
        request.httpMethod = "GET"
        request.setValue(ownerChildDeviceID.uuidString.lowercased(), forHTTPHeaderField: "X-Child-Id")
        return request
    }

    static func registration(baseURL: URL, ownerChildDeviceID: UUID, body: EpochRegistrationRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/epochs"), owner: ownerChildDeviceID, body: body)
    }

    static func activation(baseURL: URL, ownerChildDeviceID: UUID, epochID: UUID, body: EpochActivationRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/epochs/\(epochID.uuidString.lowercased())/activation"), owner: ownerChildDeviceID, body: body)
    }

    static func sample(baseURL: URL, ownerChildDeviceID: UUID, body: EpochSampleRequestDTO) throws -> URLRequest {
        try post(baseURL.appendingPathComponent("child/earned-time/sample"), owner: ownerChildDeviceID, body: body)
    }

    private static func post<Body: Encodable>(_ url: URL, owner: UUID, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(owner.uuidString.lowercased(), forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }
}
