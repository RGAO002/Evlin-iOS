import SwiftUI
import UIKit

/// Child side: generates a family on backend, displays the 6-digit code.
/// Polls for parent join in background. The child waits here until the parent
/// has paired so the next step can use the parent's selected protection mode.
struct EnterPairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var familyID: UUID?
    @Binding var childDeviceID: UUID?
    @Binding var protectionMode: String
    let onContinue: () -> Void

    @State private var pairingCode: String = ""
    @State private var status: String = "Generating code…"
    @State private var parentJoined = false
    @State private var errorText: String?
    @State private var creating = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Pair with your parent")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("Show this code to your parent. Have them open Evlin on their phone, choose Parent mode, and enter it. Stay here until the parent pairs.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            Spacer()

            Text(pairingCode.isEmpty ? "------" : pairingCode)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.evPrimary)
                .tracking(6)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.vertical, Spacing.section)
                .padding(.horizontal, Spacing.lg)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl)
                        .fill(Color.evSurfaceContainerLowest)
                        .evGhostBorder()
                )

            HStack(spacing: Spacing.md) {
                if parentJoined {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                } else if errorText == nil && !pairingCode.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Text(status)
                    .font(.evBodySmall)
                    .foregroundStyle(parentJoined ? Color.evSecondary : Color.evOnSurfaceVariant)
            }

            if let e = errorText {
                VStack(spacing: Spacing.md) {
                    Text(e)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evError)
                        .multilineTextAlignment(.center)

                    HStack(spacing: Spacing.md) {
                        Button("Use default server") {
                            apiClient.saveServerURL(APIClient.defaultURL)
                            errorText = nil
                            Task { await createFamily() }
                        }
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evPrimary)

                        Button("Retry") {
                            errorText = nil
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
                Text(parentJoined ? "Continue" : "Waiting for parent")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(parentJoined ? Color.evPrimary : Color.evOutline)
            )
            .disabled(!parentJoined)

            #if DEBUG
            // DEV ONLY: Skip waiting for parent. Without persisting `evlin.childDeviceID`,
            // the post-onboarding shell falls back to the legacy lock screen — mirror
            // `OnboardingDemoPlaceholders` + `/family/create` success path here.
            Button {
                protectionMode = "std"
                parentJoined = true
                status = "⚠️ Skipped (DEBUG) — proceeding as Std mode"

                let placeholderChild = OnboardingDemoPlaceholders.childDeviceUUID
                childDeviceID = placeholderChild
                if familyID == nil {
                    familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")
                }

                UserDefaults.standard.set(
                    placeholderChild.uuidString,
                    forKey: "evlin.childDeviceID"
                )
                if let fid = familyID {
                    UserDefaults.standard.set(fid.uuidString, forKey: "evlin.familyID")
                }

                onContinue()
            } label: {
                Text("⚠️ DEBUG: Skip pairing (single-device)")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evError)
                    .padding(.top, Spacing.md)
            }
            #endif
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
        .task { await createFamily() }
    }

    private func insertSpaces(_ s: String) -> String {
        s.map(String.init).joined(separator: " ")
    }

    /// Writes bindings + UserDefaults — must stay on the main actor so SwiftUI `@AppStorage` sees updates immediately after pairing.
    @MainActor
    private func createFamily() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        status = "Generating code…"

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
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_device_label": UIDevice.current.name,
                "protection_mode": "std",  // placeholder — parent overrides in /pair
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
                let child_device_id: UUID
                let pairing_code: String
                // code_expires_at intentionally omitted — Swift's strict ISO8601
                // decoder doesn't handle the fractional seconds in the server's
                // timestamp format. We don't use it on the client.
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            familyID = r.family_id
            childDeviceID = r.child_device_id
            pairingCode = r.pairing_code

            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.child_device_id.uuidString, forKey: "evlin.childDeviceID")

            status = "Waiting for parent to pair…"
            startPolling()
        } catch {
            errorText = error.localizedDescription
            status = "Error"
        }
    }

    private func startPolling() {
        Task {
            while !parentJoined && !Task.isCancelled && !pairingCode.isEmpty {
                do {
                    var comps = URLComponents(string: "\(apiClient.baseURL)/family/pairing-status")!
                    comps.queryItems = [URLQueryItem(name: "code", value: pairingCode)]
                    let (data, _) = try await URLSession.shared.data(from: comps.url!)
                    struct R: Codable {
                        let used: Bool
                        let protection_mode: String
                    }
                    if let r = try? JSONDecoder().decode(R.self, from: data), r.used {
                        await MainActor.run {
                            protectionMode = r.protection_mode
                            parentJoined = true
                            status = "Parent paired ✓ \(r.protection_mode == "max" ? "Maximum" : "Standard") mode"
                        }
                        break
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
