import SwiftUI
import FamilyControls

/// Child device mode — polls backend for parent commands and executes them
struct ChildModeView: View {
    @EnvironmentObject var apiClient: APIClient
    @AppStorage("childName") private var childName: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

    @StateObject private var screenTimeManager = ScreenTimeManager.shared
    @State private var statusText = "Waiting for parent commands..."
    @State private var lastAction = ""
    @State private var isLocked = false
    @State private var activeLockCount = 0
    @State private var activeLockNames: [String] = []
    @State private var lockStatusTimer: Timer?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            GlassmorphicHeader(title: "Evlin Child") {
                HeaderIconButton(systemName: "gearshape") { showSettings = true }
            }

            VStack(spacing: Spacing.section) {
                Spacer()

                // Lock status icon — reflects ActiveLockStore state
                Circle()
                    .fill((activeLockCount > 0 || isLocked) ? Color.evError.opacity(0.1) : Color.evSecondary.opacity(0.1))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: (activeLockCount > 0 || isLocked) ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 48))
                            .foregroundStyle((activeLockCount > 0 || isLocked) ? Color.evError : Color.evSecondary)
                    )

                VStack(spacing: Spacing.md) {
                    Text(childName)
                        .font(.evHeadlineMedium)
                        .foregroundStyle(Color.evPrimary)

                    Text(activeLockCount > 0
                         ? "\(activeLockCount) app\(activeLockCount == 1 ? "" : "s") locked"
                         : (isLocked ? "Device Restricted" : "No active locks"))
                        .font(.evHeadlineSmall)
                        .foregroundStyle((activeLockCount > 0 || isLocked) ? Color.evError : Color.evSecondary)

                    if !activeLockNames.isEmpty {
                        Text(activeLockNames.joined(separator: ", "))
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.section)
                    }
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
                            Task { await screenTimeManager.openScreenTimeSettings() }
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
                    Text("DEVICE ID")
                        .font(.evLabelMedium)
                        .foregroundStyle(Color.evOutline)
                        .evLabelStyle()
                    Text(childDeviceID.isEmpty ? "Not paired" : childDeviceID)
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
            screenTimeManager.enableDeletionProtection()
        }
        .onAppear {
            // CommandPoller is started at the app level (Evlin_iOSApp) so it
            // keeps running regardless of which mode/tab the user is in. This
            // view only refreshes its own lock-status display.
            startLockStatusTimer()

            if UUID(uuidString: childDeviceID) == nil {
                statusText = "Finish pairing to receive parent commands."
            }
        }
        .onDisappear {
            lockStatusTimer?.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .evlinLockStateChanged)) { note in
            if let locked = note.object as? Bool {
                isLocked = locked
            }
            refreshLockStatus()
        }
    }

    /// Starts the three-tier CommandPoller if we have a paired child device ID.
    /// The ID was persisted by EnterPairingCodeStep under "evlin.childDeviceID".
    private func startNewPoller() {
        guard let deviceID = UUID(uuidString: childDeviceID)
        else {
            print("[ChildModeView] no evlin.childDeviceID — CommandPoller not started")
            statusText = "Finish pairing to receive parent commands."
            return
        }
        CommandPoller.shared.start(deviceID: deviceID, apiClient: apiClient)
        print("[ChildModeView] CommandPoller started for device \(deviceID)")
    }

    /// Refresh lock status from ActiveLockStore every 3s so UI stays in sync
    /// with the real ManagedSettings state that CommandPoller mutated.
    private func startLockStatusTimer() {
        refreshLockStatus()
        lockStatusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in refreshLockStatus() }
        }
    }

    private func refreshLockStatus() {
        Task {
            // sweepExpired drops anything past its TTL — keeps UI honest
            _ = await ActiveLockStore.shared.sweepExpired()
            let current = await ActiveLockStore.shared.allCurrent()
            // Display combined shield + block count; see spec §3.
            let names = current.shields.map(\.displayName) + current.blocks.map(\.displayName)
            let total = current.shields.count + current.blocks.count
            await MainActor.run {
                activeLockCount = total
                activeLockNames = names
                isLocked = total > 0
                if !screenTimeManager.isAuthorized {
                    statusText = "Authorize Screen Time to receive parent commands."
                } else if childDeviceID.isEmpty {
                    statusText = "Finish pairing to receive parent commands."
                } else if total == 0 {
                    statusText = "Waiting for parent commands..."
                } else {
                    statusText = "Apps are restricted by parent"
                }
            }
        }
    }
}
