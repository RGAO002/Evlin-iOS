import SwiftUI
import UIKit

/// Parent side: enters the 6-digit code the child is displaying.
/// Struct name kept for coordinator compatibility; semantic is "enter code" now.
struct PairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var childName: String           // unused (kept for coordinator binding compat)
    @Binding var protectionMode: String
    @Binding var familyID: UUID?
    @Binding var parentDeviceID: UUID?
    @Binding var pairingCode: String
    let onContinue: () -> Void

    @State private var code: String = ""
    @State private var pairing = false
    @State private var errorText: String?
    @State private var status: String = ""

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Enter Pairing Code")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("Enter the 6-digit code your child's phone is showing.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            TextField("------", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 42, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .tracking(8)
                .padding(.vertical, Spacing.section)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl)
                        .fill(Color.evSurfaceContainerLowest)
                        .evGhostBorder()
                )
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { code = digits }
                    if digits.count > 6 { code = String(digits.prefix(6)) }
                    if digits.count == 6 && !pairing { Task { await tryPair() } }
                }

            if pairing {
                HStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Pairing…").font(.evBodySmall).foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evSecondary)
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
                        }
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evPrimary)

                        Button("Clear + retry") {
                            errorText = nil
                            code = ""
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
                    .fill(familyID != nil ? Color.evPrimary : Color.evOutline)
            )
            .disabled(familyID == nil)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private func tryPair() async {
        guard !pairing else { return }
        pairing = true
        defer { pairing = false }
        errorText = nil
        status = ""

        guard let url = URL(string: "\(apiClient.baseURL)/family/pair"),
              url.scheme != nil else {
            errorText = "Server URL is invalid. Tap 'Use default server' below."
            return
        }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 15
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code,
                "parent_device_label": UIDevice.current.name,
                "protection_mode": protectionMode,
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "?"
                errorText = "Invalid or expired code (\(http.statusCode)). \(body.prefix(200))"
                return
            }
            struct R: Codable {
                let family_id: UUID
                let parent_device_id: UUID
                let child_device_id: UUID
                let protection_mode: String
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            familyID = r.family_id
            parentDeviceID = r.parent_device_id
            pairingCode = code
            protectionMode = r.protection_mode

            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.parent_device_id.uuidString, forKey: "evlin.parentDeviceID")

            status = "Paired ✓"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
