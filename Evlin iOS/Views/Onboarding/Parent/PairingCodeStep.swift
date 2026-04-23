import SwiftUI

struct PairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var childName: String
    @Binding var protectionMode: String
    @Binding var familyID: UUID?
    @Binding var parentDeviceID: UUID?
    @Binding var pairingCode: String
    let onContinue: () -> Void

    @State private var codeExpiresAt: Date?
    @State private var status: String = "Generating code…"
    @State private var childJoined = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Pairing Code")
                .font(.evHeadlineLarge)
                .padding(.top, 40)

            Text("Open Evlin on Liam's phone and enter this code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Text(pairingCode.isEmpty ? "- - - - - -" : insertSpaces(pairingCode))
                .font(.system(size: 42, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.evPrimary)

            HStack(spacing: 8) {
                if childJoined {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(status).foregroundStyle(.secondary)
            }

            if let e = errorText {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!childJoined)
        }
        .padding()
        .task { await createFamily() }
    }

    private func insertSpaces(_ s: String) -> String {
        s.map(String.init).joined(separator: " ")
    }

    private func createFamily() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/create")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "child_name": childName,
                "protection_mode": protectionMode,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Codable {
                let family_id: UUID
                let parent_device_id: UUID
                let pairing_code: String
                let code_expires_at: Date
            }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let r = try dec.decode(R.self, from: data)
            familyID = r.family_id
            parentDeviceID = r.parent_device_id
            pairingCode = r.pairing_code
            codeExpiresAt = r.code_expires_at
            status = "Waiting for Liam's device…"
            startPolling()
        } catch {
            status = "Error"
            errorText = error.localizedDescription
        }
    }

    private func startPolling() {
        Task {
            while !childJoined && !Task.isCancelled {
                do {
                    var comps = URLComponents(string: "\(apiClient.baseURL)/family/pairing-status")!
                    comps.queryItems = [URLQueryItem(name: "code", value: pairingCode)]
                    let (data, _) = try await URLSession.shared.data(from: comps.url!)
                    struct R: Codable { let used: Bool }
                    if let r = try? JSONDecoder().decode(R.self, from: data), r.used {
                        await MainActor.run {
                            childJoined = true
                            status = "Liam's phone connected"
                        }
                        break
                    }
                } catch {
                    // swallow transient poll errors, try again
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
