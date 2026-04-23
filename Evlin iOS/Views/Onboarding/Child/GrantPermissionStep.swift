import SwiftUI
import FamilyControls

struct GrantPermissionStep: View {
    @EnvironmentObject var apiClient: APIClient
    let childDeviceID: UUID
    let protectionMode: String   // "max" | "std"
    let onContinue: () -> Void

    @State private var status: String = "Screen Time authorization is needed."
    @State private var granted = false
    @State private var requesting = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Grant Screen Time Permission")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("Evlin needs permission to manage Screen Time on this phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack(spacing: 8) {
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(status).foregroundStyle(granted ? .green : .secondary)
            }
            if let err = errorText {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            if granted {
                Button(action: onContinue) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if requesting {
                ProgressView()
            } else {
                Button {
                    Task { await request() }
                } label: {
                    Text("Grant Permission").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
    }

    private func request() async {
        requesting = true
        defer { requesting = false }
        errorText = nil
        let memberType: FamilyControlsMember = (protectionMode == "max") ? .child : .individual
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: memberType)
            granted = true
            status = "Authorization granted"
            if protectionMode == "max" {
                // Notify backend so parent WaitForAuthStep can proceed
                await grantOnBackend()
            }
        } catch {
            if protectionMode == "max" {
                errorText = "Authorization failed — confirm this phone is signed in with the Child Apple ID, then try again."
            } else {
                errorText = "Authorization failed: \(error.localizedDescription)"
            }
        }
    }

    private func grantOnBackend() async {
        do {
            let url = URL(string: "\(apiClient.baseURL)/family/auth-status/grant")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "child_device_id": childDeviceID.uuidString
            ])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("[GrantPermission] backend notify failed: \(error)")
        }
    }
}
