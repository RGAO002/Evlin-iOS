import SwiftUI

/// First-time setup: choose Parent or Child mode
struct SetupView: View {
    @AppStorage("appMode") private var appMode: String = ""
    @AppStorage("childId") private var childId: String = ""
    @AppStorage("childName") private var childName: String = ""
    @EnvironmentObject var apiClient: APIClient

    @State private var inputChildName = "Liam"
    @State private var inputPairingCode = ""
    @State private var isRegistering = false
    @State private var isPairing = false
    @State private var pairingCode = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            // Logo
            Circle()
                .fill(Color.evPrimary)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )

            Text("Evlin")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)

            Text("Choose how this device will be used")
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)

            // Mode buttons
            VStack(spacing: Spacing.xl) {
                modeButton(
                    title: "Parent Device",
                    description: "Send commands, monitor activity, manage screen time",
                    icon: "person.fill",
                    mode: "parent"
                )

                modeButton(
                    title: "Child Device",
                    description: "Receives lock/unlock commands from parent",
                    icon: "figure.child",
                    mode: "child"
                )
            }
            .padding(.horizontal, Spacing.xl)

            // Child setup
            if appMode == "child_pending" {
                VStack(spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("CHILD NAME")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        TextField("Liam", text: $inputChildName)
                            .font(.evBodyMedium)
                            .padding(Spacing.lg)
                            .background(Color.evSurfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evError)
                    }

                    Button {
                        registerChild()
                    } label: {
                        if isRegistering {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Set Up Child Device")
                                .font(.evLabelLarge)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .foregroundStyle(Color.evOnPrimary)
                    .padding(.vertical, Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evPrimary)
                    )
                    .disabled(inputChildName.isEmpty || isRegistering)
                }
                .padding(.horizontal, Spacing.xl)
            }

            // Show pairing code after child registration
            if appMode == "child_paired" {
                VStack(spacing: Spacing.xl) {
                    Text("PAIRING CODE")
                        .font(.evLabelMedium)
                        .foregroundStyle(Color.evOutline)
                        .evLabelStyle()

                    Text(pairingCode)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.evPrimary)
                        .tracking(8)

                    Text("Enter this code on the parent's device to pair")
                        .font(.evBodyMedium)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.center)

                    Button {
                        appMode = "child"
                    } label: {
                        Text("Done")
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
                .padding(.horizontal, Spacing.xl)
            }

            // Parent pairing
            if appMode == "parent_pending" {
                VStack(spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("ENTER PAIRING CODE")
                            .font(.evLabelMedium)
                            .foregroundStyle(Color.evOutline)
                            .evLabelStyle()
                        TextField("6-digit code", text: $inputPairingCode)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .padding(Spacing.lg)
                            .background(Color.evSurfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evError)
                    }

                    Button {
                        pairWithChild()
                    } label: {
                        if isPairing {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Pair")
                                .font(.evLabelLarge)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .foregroundStyle(Color.evOnPrimary)
                    .padding(.vertical, Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(inputPairingCode.count == 6 ? Color.evPrimary : Color.evPrimary.opacity(0.4))
                    )
                    .disabled(inputPairingCode.count != 6 || isPairing)

                    Button {
                        appMode = "parent"
                    } label: {
                        Text("Skip for now")
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOutline)
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }

            Spacer()
        }
        .background(Color.evSurface)
    }

    private func modeButton(title: String, description: String, icon: String, mode: String) -> some View {
        Button {
            if mode == "parent" {
                appMode = "parent_pending"
            } else {
                appMode = "child_pending"
            }
        } label: {
            HStack(spacing: Spacing.xl) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 48, height: 48)
                    .background(Color.evSurfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(title)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evPrimary)
                    Text(description)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOutline)
            }
            .padding(Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.evSurfaceContainerLowest)
                    .evGhostBorder()
            )
        }
        .buttonStyle(.plain)
    }

    private func registerChild() {
        isRegistering = true
        errorMessage = nil

        let id = UUID().uuidString
        Task {
            do {
                let url = URL(string: "\(apiClient.baseURL)/child/register")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode([
                    "child_id": id,
                    "child_name": inputChildName,
                    "device_name": UIDevice.current.name,
                ])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw APIError.serverError(0)
                }

                // Parse pairing code from response
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let code = result?["pairing_code"] as? String ?? ""

                await MainActor.run {
                    childId = id
                    childName = inputChildName
                    pairingCode = code
                    isRegistering = false
                    appMode = "child_paired"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to register: \(error.localizedDescription)"
                    isRegistering = false
                }
            }
        }
    }

    private func pairWithChild() {
        isPairing = true
        errorMessage = nil

        Task {
            do {
                let url = URL(string: "\(apiClient.baseURL)/parent/pair")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["code": inputPairingCode])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
                }

                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let pairedChildId = result?["child_id"] as? String ?? ""
                let pairedChildName = result?["child_name"] as? String ?? "Child"

                await MainActor.run {
                    UserDefaults.standard.set(pairedChildId, forKey: "targetChildId")
                    childName = pairedChildName
                    appMode = "parent"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Invalid code or connection error"
                    isPairing = false
                }
            }
        }
    }
}
