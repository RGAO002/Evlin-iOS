import SwiftUI
import FamilyControls

/// Child device mode — polls backend for parent commands and executes them
struct ChildModeView: View {
    @EnvironmentObject var apiClient: APIClient
    @AppStorage("childId") private var childId: String = ""
    @AppStorage("childName") private var childName: String = ""

    @StateObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var statusText = "Waiting for parent commands..."
    @State private var lastAction = ""
    @State private var pollTimer: Timer?
    @State private var isLocked = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            GlassmorphicHeader {
                showSettings = true
            }

            VStack(spacing: Spacing.section) {
                Spacer()

                // Lock status icon
                Circle()
                    .fill(isLocked ? Color.evError.opacity(0.1) : Color.evSecondary.opacity(0.1))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(isLocked ? Color.evError : Color.evSecondary)
                    )

                VStack(spacing: Spacing.md) {
                    Text(childName)
                        .font(.evHeadlineMedium)
                        .foregroundStyle(Color.evPrimary)

                    Text(isLocked ? "Device Restricted" : "Device Unlocked")
                        .font(.evHeadlineSmall)
                        .foregroundStyle(isLocked ? Color.evError : Color.evSecondary)
                }

                Text(statusText)
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.section)

                if !lastAction.isEmpty {
                    Text(lastAction)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOutline)
                        .padding(.horizontal, Spacing.section)
                }

                // Authorization status + button
                VStack(spacing: Spacing.md) {
                    HStack(spacing: Spacing.md) {
                        Circle()
                            .fill(screenTimeManager.isAuthorized ? Color.evSecondary : Color.evError)
                            .frame(width: 8, height: 8)
                        Text(screenTimeManager.isAuthorized ? "Screen Time Authorized" : "Screen Time Not Authorized")
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }

                    if !screenTimeManager.isAuthorized {
                        Button {
                            Task { await screenTimeManager.requestAuthorization() }
                        } label: {
                            Text("Authorize Screen Time")
                                .font(.evLabelLarge)
                                .foregroundStyle(Color.evOnPrimary)
                                .padding(.horizontal, Spacing.xxxl)
                                .padding(.vertical, Spacing.lg)
                                .background(
                                    RoundedRectangle(cornerRadius: CornerRadius.md)
                                        .fill(Color.evPrimary)
                                )
                        }

                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("Open Screen Time Settings")
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOutline)
                                .padding(.top, Spacing.sm)
                        }
                    }
                }

                Spacer()

                // Child ID for parent reference
                VStack(spacing: Spacing.sm) {
                    Text("CHILD ID")
                        .font(.evLabelMedium)
                        .foregroundStyle(Color.evOutline)
                        .evLabelStyle()
                    Text(childId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .textSelection(.enabled)
                }
                .padding(.bottom, Spacing.section)
            }
        }
        .background(Color.evSurface)
        .task {
            #if !targetEnvironment(simulator)
            if !screenTimeManager.isAuthorized {
                await screenTimeManager.requestAuthorization()
            }
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            startPolling()
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // Immediate check
        Task { await pollOnce() }

        // Poll every 10 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { await pollOnce() }
        }
        if let timer = pollTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func pollOnce() async {
        guard !childId.isEmpty else { return }

        let urlString = "\(apiClient.baseURL)/child/pending-actions/\(childId)"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let actions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            for action in actions {
                guard let actionId = action["action_id"] as? String,
                      let actionType = action["action_type"] as? String else { continue }

                let params = action["params"] as? [String: Any]

                await MainActor.run {
                    executeAction(type: actionType, rawParams: params)
                }

                await acknowledgeAction(actionId: actionId)
            }

            await MainActor.run {
                statusText = isLocked ? "Apps are restricted by parent" : "Waiting for parent commands..."
            }
        } catch {
            await MainActor.run {
                statusText = "Connection error — retrying..."
            }
        }
    }

    private func executeAction(type: String, rawParams: [String: Any]?) {
        print("[Child] executeAction: \(type), params: \(String(describing: rawParams))")
        print("[Child] isAuthorized: \(screenTimeManager.isAuthorized)")
        switch type {
        case "lock":
            let minutes = rawParams?["minutes"] as? Int ?? 0
            #if !targetEnvironment(simulator)
            screenTimeManager.shieldAllApps()
            #endif
            isLocked = true
            lastAction = "Locked by parent\(minutes > 0 ? " for \(minutes) min" : "")"

            // Auto-unlock after N minutes
            if minutes > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                    await MainActor.run {
                        screenTimeManager.clearAllShields()
                        isLocked = false
                        lastAction = "Auto-unlocked after \(minutes) min"
                    }
                }
            }

        case "unlock":
            #if !targetEnvironment(simulator)
            screenTimeManager.clearAllShields()
            #endif
            isLocked = false
            lastAction = "Unlocked by parent"

        default:
            lastAction = "Unknown action: \(type)"
        }
    }

    private func acknowledgeAction(actionId: String) async {
        guard let url = URL(string: "\(apiClient.baseURL)/child/ack/\(actionId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }
}
