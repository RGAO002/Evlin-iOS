import Foundation

/// Single owner for Parent PIN network convergence. This is intentionally a
/// separate lane from command delivery and metering recovery.
@MainActor
enum ParentPINSyncCoordinator {
    typealias UploadSender = (PendingParentPINUpload) async -> Bool
    typealias ClearSender = (PendingParentPINClear) async -> Bool

    static func captureNewPIN(_ pin: String) {
        guard let deviceID = currentChildDeviceID() else { return }
        ParentPINLifecycleStore.shared.captureUpload(
            pin: pin,
            status: "available",
            deviceID: deviceID,
            baseURL: APIClient.currentBaseURL
        )
        Task { await flushPending() }
    }

    /// A local PIN is identity-scoped. Keep it only when the lifecycle store
    /// can prove that it belongs to the device identity just adopted; an
    /// unproved hash may be residue from a deleted account or prior child.
    static func prepareForAdoption(
        deviceID: UUID,
        pinStore: EvlinPINStore = .shared,
        store: ParentPINLifecycleStore = .shared
    ) {
        let belongsToAdoptedDevice = store.hasLifecycleProof(for: deviceID)
        store.discardPendingUpload(unlessDeviceID: deviceID)
        if pinStore.isSet() && !belongsToAdoptedDevice {
            pinStore.clear()
        }
    }

    static func prepareSignOut() {
        guard let deviceID = currentChildDeviceID() else { return }
        ParentPINLifecycleStore.shared.prepareSignOutClear(
            deviceID: deviceID,
            baseURL: APIClient.currentBaseURL
        )
    }

    static func runForeground() async {
        guard let deviceID = currentChildDeviceID() else { return }
        let baseURL = APIClient.currentBaseURL
        let remoteStatus = await ParentPINStatusClient.fetchStatus(
            baseURL: baseURL,
            deviceID: deviceID
        )
        if let remoteStatus {
            _ = ParentPINBackfill.shared.applyRemoteReset(
                remoteStatus,
                deviceID: deviceID
            )
        }
        await flushPending()
        await ParentPINBackfill.shared.runIfNeeded(
            deviceID: deviceID,
            baseURL: baseURL,
            remoteStatus: remoteStatus
        )
        await flushPending()
    }

    /// Used by onboarding's completion gate. A local PIN alone is insufficient:
    /// the parent app can recover it only after the backend acknowledges it.
    static func ensureCurrentPINAvailable() async -> Bool {
        guard let deviceID = currentChildDeviceID() else { return false }
        await flushPending()
        guard let status = await ParentPINStatusClient.fetchStatus(
            baseURL: APIClient.currentBaseURL,
            deviceID: deviceID
        ) else { return false }
        return status.status == "available"
    }

    /// Gate-time check so a parent-authorized reset wins before a cached PIN
    /// can unlock Parent Controls. Transport failure preserves offline access;
    /// the monotonic backend generation still prevents stale re-upload.
    @discardableResult
    static func reconcileRemoteReset() async -> Bool {
        guard let deviceID = currentChildDeviceID() else { return false }
        guard let status = await ParentPINStatusClient.fetchStatus(
            baseURL: APIClient.currentBaseURL,
            deviceID: deviceID
        ) else { return false }
        return ParentPINBackfill.shared.applyRemoteReset(status, deviceID: deviceID)
    }

    static func flushPending(
        store providedStore: ParentPINLifecycleStore? = nil,
        sendUpload: UploadSender? = nil,
        sendClear: ClearSender? = nil
    ) async {
        let store = providedStore ?? .shared
        let uploadSender = sendUpload ?? postUpload
        let clearSender = sendClear ?? postClear
        if let upload = store.pendingUpload(), await uploadSender(upload) {
            store.acknowledgeUpload(upload)
        }
        for clear in store.pendingClears() where await clearSender(clear) {
            store.acknowledgeClear(clear)
        }
    }

    private static func currentChildDeviceID() -> UUID? {
        let raw = UserDefaults.standard.string(
            forKey: CommandPoller.childDeviceIDDefaultsKey
        )
        return raw.flatMap(UUID.init(uuidString:))
    }

    private static func postUpload(_ upload: PendingParentPINUpload) async -> Bool {
        await post(
            baseURL: upload.baseURL,
            path: "/child/device/parent-pin",
            method: "PUT",
            deviceID: upload.deviceID,
            body: [
                "pin": upload.pin as Any,
                "status": upload.status,
                "lifecycle_secret": upload.lifecycleSecret,
                "reset_generation": upload.resetGeneration,
            ]
        )
    }

    private static func postClear(_ clear: PendingParentPINClear) async -> Bool {
        await post(
            baseURL: clear.baseURL,
            path: "/child/device/parent-pin/clear",
            method: "POST",
            deviceID: clear.deviceID,
            body: ["lifecycle_secret": clear.lifecycleSecret]
        )
    }

    private static func post(
        baseURL: String,
        path: String,
        method: String,
        deviceID: UUID,
        body: [String: Any]
    ) async -> Bool {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Child-Id")
        request.httpBody = data
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }
}

enum ParentPINStatusClient {
    static func fetchStatus(baseURL: String, deviceID: UUID) async -> ParentPINRemoteStatus? {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/child/device/parent-pin-status") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Child-Id")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return nil
        }
        guard let status = json["parent_pin_status"] as? String,
              let generation = json["reset_generation"] as? Int else {
            return nil
        }
        return ParentPINRemoteStatus(status: status, resetGeneration: generation)
    }
}
