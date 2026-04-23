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
    @State private var creating = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Pairing Code")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Open Evlin on your child's phone and enter this code.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            Spacer()

            Text(pairingCode.isEmpty ? "------" : insertSpaces(pairingCode))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.evPrimary)
                .tracking(8)
                .padding(.vertical, Spacing.section)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl)
                        .fill(Color.evSurfaceContainerLowest)
                        .evGhostBorder()
                )

            HStack(spacing: Spacing.md) {
                if childJoined {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                } else if errorText == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(status)
                    .font(.evBodySmall)
                    .foregroundStyle(childJoined ? Color.evSecondary : Color.evOnSurfaceVariant)
            }

            if let e = errorText {
                VStack(spacing: Spacing.md) {
                    Text(e)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evError)
                        .multilineTextAlignment(.center)

                    Text("Server:")
                        .font(.caption2)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    Text(apiClient.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.center)

                    HStack(spacing: Spacing.md) {
                        Button("Use default server") {
                            apiClient.saveServerURL(APIClient.defaultURL)
                            errorText = nil
                            status = "Retrying…"
                            Task { await createFamily() }
                        }
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evPrimary)

                        Button("Retry") {
                            errorText = nil
                            status = "Retrying…"
                            Task { await createFamily() }
                        }
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evPrimary)
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(childJoined ? Color.evPrimary : Color.evOutline)
            )
            .disabled(!childJoined)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
        .task { await createFamily() }
    }

    private func insertSpaces(_ s: String) -> String {
        s.map(String.init).joined(separator: " ")
    }

    private func createFamily() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        status = "Generating code…"
        errorText = nil

        // Guard against malformed baseURL (e.g. missing scheme from user input)
        guard let url = URL(string: "\(apiClient.baseURL)/family/create"),
              url.scheme != nil else {
            errorText = "Server URL is invalid. Tap 'Use default server' below."
            status = "Error"
            return
        }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15
            let effectiveChildName = childName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Child"
                : childName
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_name": effectiveChildName,
                "protection_mode": protectionMode,
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "?"
                errorText = "Server returned \(http.statusCode). \(body.prefix(200))"
                status = "Error"
                return
            }
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
            status = "Waiting for child device…"
            startPolling()
        } catch {
            errorText = error.localizedDescription
            status = "Error"
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
                            status = "Child's phone connected"
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
