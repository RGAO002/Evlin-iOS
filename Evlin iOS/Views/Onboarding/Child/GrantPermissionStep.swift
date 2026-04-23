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
        VStack(spacing: Spacing.section) {
            Spacer()

            Circle()
                .fill(Color.evPrimary)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "hourglass")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            VStack(spacing: Spacing.lg) {
                Text("Grant Screen Time Permission")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("Evlin needs permission to manage Screen Time on this phone.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            HStack(spacing: Spacing.md) {
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                }
                Text(status)
                    .font(.evBodySmall)
                    .foregroundStyle(granted ? Color.evSecondary : Color.evOnSurfaceVariant)
            }

            if let err = errorText {
                Text(err)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            if granted {
                primaryButton(title: "Continue", action: onContinue)
            } else if requesting {
                ProgressView()
            } else {
                primaryButton(title: "Grant Permission") {
                    Task { await request() }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    @ViewBuilder
    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.evLabelLarge)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.evOnPrimary)
        .padding(.vertical, Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.evPrimary)
        )
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
