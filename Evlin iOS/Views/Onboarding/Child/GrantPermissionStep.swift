import SwiftUI
import FamilyControls
import UserNotifications

struct GrantPermissionStep: View {
    @EnvironmentObject var apiClient: APIClient
    let childDeviceID: UUID
    let protectionMode: String   // "max" | "std"
    let onContinue: () -> Void

    @State private var status: String = "Screen Time authorization is needed."
    @State private var granted = false
    @State private var requesting = false
    @State private var notificationRequested = false
    @State private var requestingNotifications = false
    @State private var deletionProtectionOn = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: Spacing.lg) {
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
                Text("Grant access")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)
                Text("Finish these on this phone before your parent can send the first block.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            VStack(spacing: Spacing.md) {
                accessRow(
                    title: "Screen Time",
                    subtitle: status,
                    done: granted,
                    buttonTitle: requesting ? "Requesting…" : (granted ? "Granted" : "Grant"),
                    disabled: requesting || granted,
                    action: { Task { await requestScreenTime() } }
                )

                accessRow(
                    title: "Notifications",
                    subtitle: notificationRequested
                        ? "Notification request completed."
                        : "Evlin can tell you when rules change.",
                    done: notificationRequested,
                    buttonTitle: requestingNotifications
                        ? "Requesting…" : (notificationRequested ? "Done" : "Allow"),
                    disabled: requestingNotifications || notificationRequested,
                    action: { Task { await requestNotifications() } }
                )

                HStack(alignment: .center, spacing: Spacing.md) {
                    Image(systemName: deletionProtectionOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(deletionProtectionOn ? Color.evSecondary : Color.evOnSurfaceVariant)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prevent app deletion")
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evPrimary)
                        Text("Default on. iOS applies this phone-wide.")
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                    Spacer()
                    Toggle("", isOn: $deletionProtectionOn)
                        .labelsHidden()
                        .onChange(of: deletionProtectionOn) { _, newValue in
                            ScreenTimeManager.shared.setDeletionProtectionEnabled(newValue)
                        }
                }
                .padding(Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.evSurfaceContainer)
                )
            }
            .padding(.horizontal, Spacing.lg)

            if let err = errorText {
                Text(err)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            primaryButton(title: "Continue") {
                ScreenTimeManager.shared.setDeletionProtectionEnabled(deletionProtectionOn)
                onContinue()
            }
            .opacity(granted ? 1 : 0.5)
            .disabled(!granted)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
        .onAppear {
            deletionProtectionOn = true
            ScreenTimeManager.shared.setDeletionProtectionEnabled(true)
        }
    }

    @ViewBuilder
    private func accessRow(
        title: String,
        subtitle: String,
        done: Bool,
        buttonTitle: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.evSecondary : Color.evOnSurfaceVariant)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                Text(subtitle)
                    .font(.evBodySmall)
                    .foregroundStyle(done ? Color.evSecondary : Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: action) {
                Text(buttonTitle)
                    .font(.evLabelSmall)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(done ? Color.evSecondary.opacity(0.12) : Color.evPrimary)
                    )
                    .foregroundStyle(done ? Color.evSecondary : Color.evOnPrimary)
            }
            .disabled(disabled)
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.evSurfaceContainer)
        )
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

    private func requestScreenTime() async {
        requesting = true
        defer { requesting = false }
        errorText = nil
        // Max mode requires Child Apple ID (.child auth); Standard uses .individual.
        let memberType: FamilyControlsMember = (protectionMode == "max") ? .child : .individual
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: memberType)
            granted = true
            status = "Authorization granted"
            // Notify the backend that this child device's Screen Time auth
            // landed. In Max mode the parent's WaitForAuth poll gates on it; in
            // Std (the v2 default) it's harmless + idempotent, and keeps the
            // child_auth_granted flag truthful for the parent's child-device row.
            await grantOnBackend()
        } catch {
            if protectionMode == "max" {
                errorText = "Authorization failed — confirm this phone is signed in with the Child Apple ID, then try again."
            } else {
                errorText = "Authorization failed: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func requestNotifications() async {
        requestingNotifications = true
        defer { requestingNotifications = false }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        notificationRequested = true
    }

    private func grantOnBackend() async {
        do {
            try await apiClient.grantChildAuthStatus(childDeviceID: childDeviceID)
        } catch {
            print("[GrantPermission] backend notify failed: \(error)")
        }
    }
}
