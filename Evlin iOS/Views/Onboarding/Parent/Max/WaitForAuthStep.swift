import SwiftUI

struct WaitForAuthStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let onContinue: () -> Void

    @State private var status: String = "Waiting for child device…"
    @State private var granted = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Waiting for Authorization")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("Pick up Liam's phone. Evlin there will prompt for parent authorization. Approve when iOS asks you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack(spacing: 8) {
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ProgressView()
                }
                Text(status).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!granted)
        }
        .padding()
        .task { await poll() }
    }

    private func poll() async {
        while !granted && !Task.isCancelled {
            do {
                var comps = URLComponents(string: "\(apiClient.baseURL)/family/auth-status")!
                comps.queryItems = [URLQueryItem(name: "family_id", value: familyID.uuidString)]
                let (data, _) = try await URLSession.shared.data(from: comps.url!)
                struct R: Codable { let granted: Bool }
                if let r = try? JSONDecoder().decode(R.self, from: data), r.granted {
                    await MainActor.run {
                        granted = true
                        status = "Parent authorization granted"
                    }
                    break
                }
            } catch {
                // transient — retry
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
