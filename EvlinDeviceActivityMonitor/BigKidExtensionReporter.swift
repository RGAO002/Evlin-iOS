import Foundation

actor BigKidExtensionReporter {
    static let shared = BigKidExtensionReporter()

    func reportChunk() async {
        guard let baseURL = ExtensionConfig.baseURL,
              let childId = ExtensionConfig.childId else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("child/time-consumption"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(childId.uuidString, forHTTPHeaderField: "X-Child-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["minutes_used": 5])
        _ = try? await URLSession.shared.data(for: req)
    }

    func reportCommandHeartbeat() async {
        guard let baseURL = ExtensionConfig.baseURL,
              let childId = ExtensionConfig.childId else {
            ExtensionConfig.recordCommandHeartbeat("skipped missing baseURL/childId")
            return
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("child/heartbeat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": childId.uuidString
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            ExtensionConfig.recordCommandHeartbeat(
                "reported /child/heartbeat status=\(status) device=\(childId.uuidString)"
            )
        } catch {
            ExtensionConfig.recordCommandHeartbeat(
                "failed /child/heartbeat error=\(error.localizedDescription)"
            )
        }
    }
}

enum ExtensionConfig {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.evlin.ios")
    }

    static var baseURL: URL? {
        let v = defaults?.string(forKey: "evlin.baseURL")
        return v.flatMap { URL(string: $0) }
    }
    static var childId: UUID? {
        let v = defaults?.string(forKey: "evlin.childId")
        return v.flatMap { UUID(uuidString: $0) }
    }

    static func recordCommandHeartbeat(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        defaults?.set("\(ts) \(message)", forKey: "evlin.delivery.damHeartbeat")
    }
}
