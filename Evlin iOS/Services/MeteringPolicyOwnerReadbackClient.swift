import Foundation

nonisolated enum MeteringPolicyOwnerReadbackError: Error, Equatable {
    case unexpectedHTTPStatus(Int)
}

nonisolated final class MeteringPolicyOwnerReadbackClient: @unchecked Sendable {
    private let baseURL: URL
    private let transport: any MeteringHTTPTransport

    init(baseURL: URL, transport: any MeteringHTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func confirm(_ policy: MeteringDesiredPolicy) async throws {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("child")
                .appendingPathComponent("ack")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command_id": policy.commandID.uuidString,
            "device_id": policy.ownerChildDeviceID.uuidString,
            "status": "confirmed",
            "detail": [
                "source": "device_epoch_owner_readback",
                "application_state": "applied",
                "ordering_token": policy.orderingToken,
                "policy_revision": policy.policyRevision,
                "usage_date": policy.usageDate,
                "canonical_timezone": policy.canonicalTimezone,
                "daily_pool_minutes": policy.dailyPoolMinutes,
                "device_cap_minutes": policy.deviceCapMinutes,
                "owner_child_device_id": policy.ownerChildDeviceID.uuidString,
            ],
        ])
        let (_, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard 200..<300 ~= status else {
            throw MeteringPolicyOwnerReadbackError.unexpectedHTTPStatus(status)
        }
    }
}
