import Foundation
import UIKit

/// Single-device demo: create a family on the adaptive-engine and pair this
/// device as both “child” creator and “parent” completer — same HTTP sequence as
/// `SpikeView.setupTestMode()`. Writes real `evlin.familyID` / `evlin.childDeviceID`
/// so `/parent/chat` can queue shield/lock commands and `CommandPoller` can fetch them.
enum DemoFamilyBootstrap {

    struct PairingResult: Sendable {
        let familyID: UUID
        let childDeviceID: UUID
        let parentDeviceID: UUID
        let protectionMode: String
    }

    private struct CreateFamilyResponse: Decodable {
        let family_id: UUID
        let child_device_id: UUID
        let pairing_code: String
    }

    private struct PairFamilyResponse: Decodable {
        let family_id: UUID
        let child_device_id: UUID
        let parent_device_id: UUID
        let protection_mode: String
    }

    enum BootstrapError: Error {
        case badBaseURL
        case http(Int, String)
    }

    static func pairSingleDeviceOnBackend(baseURL raw: String) async throws -> PairingResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let createURL = URL(string: trimmed + "/family/create"),
              let pairURL = URL(string: trimmed + "/family/pair")
        else { throw BootstrapError.badBaseURL }

        let deviceTag = UIDevice.current.name

        var req1 = URLRequest(url: createURL)
        req1.httpMethod = "POST"
        req1.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req1.timeoutInterval = 35
        req1.httpBody = try JSONSerialization.data(withJSONObject: [
            "child_device_label": deviceTag + " (demo child)",
            "protection_mode": "std",
        ])
        let (data1, resp1) = try await URLSession.shared.data(for: req1)
        let code1 = (resp1 as? HTTPURLResponse)?.statusCode ?? 0
        guard code1 == 200 else {
            throw BootstrapError.http(code1, String(data: data1, encoding: .utf8) ?? "")
        }
        let created = try JSONDecoder().decode(CreateFamilyResponse.self, from: data1)

        var req2 = URLRequest(url: pairURL)
        req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.timeoutInterval = 35
        req2.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": created.pairing_code,
            "parent_device_label": deviceTag + " (demo parent)",
            "protection_mode": "std",
        ])
        let (data2, resp2) = try await URLSession.shared.data(for: req2)
        let code2 = (resp2 as? HTTPURLResponse)?.statusCode ?? 0
        guard code2 == 200 else {
            throw BootstrapError.http(code2, String(data: data2, encoding: .utf8) ?? "")
        }
        let paired = try JSONDecoder().decode(PairFamilyResponse.self, from: data2)

        return PairingResult(
            familyID: paired.family_id,
            childDeviceID: paired.child_device_id,
            parentDeviceID: paired.parent_device_id,
            protectionMode: paired.protection_mode
        )
    }
}
