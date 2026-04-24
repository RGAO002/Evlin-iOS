import SwiftUI

struct WaitForAuthStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let onContinue: () -> Void

    @State private var status: String = "Waiting for child device…"
    @State private var granted = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Approve Evlin on the child phone")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("On the child phone, continue Evlin onboarding and tap Grant Permission. iOS should ask the parent or guardian to approve Screen Time access.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            Spacer()

            VStack(spacing: Spacing.lg) {
                if granted {
                    Circle()
                        .fill(Color.evSecondaryContainer)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(Color.evSecondary)
                        )
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(status)
                    .font(.evBodyMedium)
                    .foregroundStyle(granted ? Color.evSecondary : Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if !granted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("If it fails:")
                        .font(.evLabelMedium)
                        .foregroundStyle(Color.evPrimary)
                    Text("Check that the child phone is signed in with the Child Apple Account and is in the same Family Sharing group.")
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                .padding(Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(Color.evSurfaceContainerLowest)
                )
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(granted ? Color.evPrimary : Color.evOutline)
            )
            .disabled(!granted)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
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
