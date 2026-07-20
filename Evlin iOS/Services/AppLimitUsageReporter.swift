import Foundation

nonisolated struct AppLimitUsageServerResponse: Codable, Equatable, Sendable {
    let ruleID: UUID
    let usageDate: String
    let usedMinutes: Int
    let accepted: Bool
    let currentOrderingToken: Int64
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case usageDate = "usage_date"
        case usedMinutes = "used_minutes"
        case accepted
        case currentOrderingToken = "current_ordering_token"
        case reason
    }

    static func accepted(
        ruleID: UUID,
        usageDate: String,
        usedMinutes: Int,
        currentOrderingToken: Int64
    ) -> Self {
        Self(
            ruleID: ruleID,
            usageDate: usageDate,
            usedMinutes: usedMinutes,
            accepted: true,
            currentOrderingToken: currentOrderingToken,
            reason: nil
        )
    }

    static func rejected(
        ruleID: UUID,
        usageDate: String,
        currentOrderingToken: Int64,
        reason: String
    ) -> Self {
        Self(
            ruleID: ruleID,
            usageDate: usageDate,
            usedMinutes: 0,
            accepted: false,
            currentOrderingToken: currentOrderingToken,
            reason: reason
        )
    }
}

nonisolated enum AppLimitUsageReporterError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case responseMismatch
}

/// Builds and sends one versioned per-app usage observation. Retry ownership is
/// the durable effect journal; this adapter never treats status alone as proof
/// that the backend accepted a sample.
nonisolated enum AppLimitUsageReporter {
    static func clientSampleID(for callback: AppLimitValidatedCallback) -> String {
        let suffix = callback.effectKind == .enforcement
            ? "budget"
            : "t\(callback.rawThresholdMinutes)"
        return [
            "applimit",
            callback.rule.id.uuidString.lowercased(),
            "r\(callback.provenance.ruleRevision)",
            "a\(callback.provenance.armID.uuidString.lowercased())",
            callback.provenance.usageDate,
            suffix,
        ].joined(separator: ":")
    }

    static func makeBody(
        deviceID: UUID,
        ruleID: UUID,
        orderingToken: Int64,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        observedAt: String,
        clientSampleID: String
    ) -> [String: Any] {
        let normalizedRuleID = ruleID.uuidString.lowercased()
        return [
            "child_device_id": deviceID.uuidString,
            "rule_id": normalizedRuleID,
            "ordering_token": orderingToken,
            "usage_date": usageDate,
            "timezone": timezone,
            "threshold_minutes": thresholdMinutes,
            "estimated_minutes": estimatedMinutes,
            "observed_at": observedAt,
            "client_sample_id": clientSampleID,
        ]
    }

    static func request(
        baseURL: URL,
        deviceID: UUID,
        ruleID: UUID,
        orderingToken: Int64,
        usageDate: String,
        timezone: String,
        thresholdMinutes: Int,
        estimatedMinutes: Int,
        observedAt: Date,
        clientSampleID: String
    ) throws -> URLRequest {
        let body = makeBody(
            deviceID: deviceID,
            ruleID: ruleID,
            orderingToken: orderingToken,
            usageDate: usageDate,
            timezone: timezone,
            thresholdMinutes: thresholdMinutes,
            estimatedMinutes: estimatedMinutes,
            observedAt: ISO8601DateFormatter().string(from: observedAt),
            clientSampleID: clientSampleID
        )
        var request = URLRequest(
            url: baseURL.appendingPathComponent("child/app-limit/usage-sample")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func submit(
        baseURL: URL,
        deviceID: UUID,
        callback: AppLimitValidatedCallback,
        transport: any MeteringHTTPTransport,
        observedAt: Date
    ) async throws -> AppLimitUsageServerResponse {
        let request = try request(
            baseURL: baseURL,
            deviceID: deviceID,
            ruleID: callback.rule.id,
            orderingToken: callback.provenance.ruleRevision,
            usageDate: callback.provenance.usageDate,
            timezone: callback.provenance.timezone,
            thresholdMinutes: callback.adjustedEstimateMinutes,
            estimatedMinutes: callback.adjustedEstimateMinutes,
            observedAt: observedAt,
            clientSampleID: clientSampleID(for: callback)
        )
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppLimitUsageReporterError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppLimitUsageReporterError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(AppLimitUsageServerResponse.self, from: data),
              decoded.ruleID == callback.rule.id,
              decoded.usageDate == callback.provenance.usageDate,
              decoded.currentOrderingToken > 0
        else { throw AppLimitUsageReporterError.responseMismatch }
        return decoded
    }
}
