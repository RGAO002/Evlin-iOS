import Foundation

@MainActor
final class HTTPAppLimitOwnerReadbackClient: AppLimitOwnerReadbackPort, @unchecked Sendable {
    private let api: APIClient
    private let ownerChildDeviceID: UUID

    init(baseURL: URL, ownerChildDeviceID: UUID) {
        api = APIClient(baseURL: baseURL.absoluteString)
        self.ownerChildDeviceID = ownerChildDeviceID
    }

    func confirm(commandID: UUID, receipt: AppLimitApplyReceipt) async throws {
        try await api.ack(
            commandID: commandID,
            deviceID: ownerChildDeviceID,
            status: "confirmed",
            detail: Self.detail(for: receipt)
        )
    }

    static func detail(for receipt: AppLimitApplyReceipt) -> [String: Any] {
        let verb = receipt.commandKind == .set ? "set_limit" : "clear_limit"
        let applicationState = receipt.commandKind == .set ? "applied" : "cleared"
        var detail: [String: Any] = [
            "verb": verb,
            "rule_id": receipt.ruleID.uuidString,
            "ordering_token": receipt.orderingToken,
            "application_state": applicationState,
            "owner": "main_app",
            "source": "monitor_owner_readback",
            "receipt_revision": receipt.storeRevision,
            "receipt_source": receipt.source,
        ]
        if let armID = receipt.armID { detail["arm_id"] = armID.uuidString }
        return detail
    }
}
