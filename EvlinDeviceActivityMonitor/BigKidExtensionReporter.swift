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
}

enum ExtensionConfig {
    static var baseURL: URL? {
        let v = UserDefaults(suiteName: "group.com.evlin.ios")?.string(forKey: "evlin.baseURL")
        return v.flatMap { URL(string: $0) }
    }
    static var childId: UUID? {
        let v = UserDefaults(suiteName: "group.com.evlin.ios")?.string(forKey: "evlin.childId")
        return v.flatMap { UUID(uuidString: $0) }
    }
}
