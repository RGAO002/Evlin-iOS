import SwiftUI
import UIKit

struct EnterPairingCodeStep: View {
    @EnvironmentObject var apiClient: APIClient
    @Binding var familyID: UUID?
    @Binding var childDeviceID: UUID?
    @Binding var protectionMode: String
    let onContinue: () -> Void

    @State private var code: String = ""
    @State private var error: String?
    @State private var pairing = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Enter Pairing Code")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Enter the 6-digit code from your parent's Evlin.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("PAIRING CODE")
                    .font(.evLabelMedium)
                    .foregroundStyle(Color.evOutline)
                    .evLabelStyle()
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.evPrimary)
                    .tracking(8)
                    .multilineTextAlignment(.center)
                    .padding(Spacing.lg)
                    .background(Color.evSurfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                    .onChange(of: code) { _, newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        if digitsOnly != newValue { code = digitsOnly }
                        if digitsOnly.count == 6 && !pairing {
                            Task { await pair() }
                        }
                    }
            }

            if let err = error {
                Text(err)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
            }

            if pairing {
                ProgressView()
            }

            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        error = nil
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/pair")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "code": code,
                "device_label": UIDevice.current.name,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                error = "Invalid or expired code."
                return
            }
            struct R: Codable {
                let family_id: UUID
                let child_device_id: UUID
                let parent_device_id: UUID
                let protection_mode: String
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            familyID = r.family_id
            childDeviceID = r.child_device_id
            protectionMode = r.protection_mode
            // Persist for later CommandPoller start
            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.child_device_id.uuidString, forKey: "evlin.childDeviceID")
            UserDefaults.standard.set(r.protection_mode, forKey: "evlin.protectionMode")
            onContinue()
        } catch {
            self.error = "Could not pair: \(error.localizedDescription)"
        }
    }
}
