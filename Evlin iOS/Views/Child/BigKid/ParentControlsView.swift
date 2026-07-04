import SwiftUI
import UserNotifications

enum ParentControlsPresentation {
    enum AppearAction: Equatable {
        case syncDeletionProtection
        case refreshNotificationStatus
    }

    static let appearActions: [AppearAction] = [
        .syncDeletionProtection,
        .refreshNotificationStatus,
    ]
}

/// PIN-gated "Parent controls" hub on the kid device. Drills into the existing
/// LockListManagerView, exposes Screen Time / Notifications / delete-protection /
/// read-only device info, and a local-reset Sign out. No backend calls.
struct ParentControlsView: View {
    let familyID: UUID
    let childDeviceID: UUID
    /// Performs the local-reset teardown + dismiss. Owned by the caller.
    let onSignOut: () -> Void
    let onClose: () -> Void

    @ObservedObject private var screenTime = ScreenTimeManager.shared
    @State private var notifAuthorized = false
    @State private var showLockList = false
    @State private var showSignOutConfirm = false
    @State private var showScreenTimeCapture = false

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { screenTime.deletionProtectionEnabled },
            set: { screenTime.setDeletionProtectionEnabled($0) }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showLockList = true } label: {
                        rowLabel(icon: "square.grid.2x2.fill", title: "App Controls",
                                 subtitle: "Choose what Evlin can lock & monitor", trailingChevron: true,
                                 badgeColor: EvlinKidColors.green700)
                    }
                    // Screen Time tracking capture. The kid
                    // home shows this once (EarnedTimeStore.measurementSelection == nil)
                    // then it vanishes; this parent-menu row is the durable entry point
                    // so a parent can (re-)capture whole-device coverage anytime. Both
                    // surfaces present the SAME ScreenTimeCaptureView.
                    Button { showScreenTimeCapture = true } label: {
                        rowLabel(icon: "chart.bar.xaxis", title: "Screen Time Tracking",
                                 subtitle: "Choose what counts toward daily screen time", trailingChevron: true,
                                 badgeColor: EvlinKidColors.green700)
                    }
                }

                Section("Permissions") {
                    HStack {
                        rowLabel(icon: "hourglass", title: "Screen Time access")
                        Spacer()
                        if screenTime.isAuthorized {
                            statusPill("On")
                        } else {
                            Button("Turn on") { Task { await screenTime.requestScreenTimeAuthorization() } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    HStack {
                        rowLabel(icon: "bell.fill", title: "Notifications")
                        Spacer()
                        if notifAuthorized {
                            statusPill("On")
                        } else {
                            Button("Turn on") { requestNotifications() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }

                Section("Protection") {
                    Toggle(isOn: deletionBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prevent deleting Evlin").font(.system(size: 15))
                            Text("This also prevents deleting any other apps on this phone.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if !screenTime.isAuthorized {
                                Text("Turn on Screen Time access first.")
                                    .font(.system(size: 12)).foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(!screenTime.isAuthorized)
                }

                Section("Device") {
                    LabeledContent("Paired", value: "Yes")
                    LabeledContent("Device ID", value: String(childDeviceID.uuidString.prefix(8)) + "…")
                        .textSelection(.enabled)
                }

                Section {
                    Button(role: .destructive) { showSignOutConfirm = true } label: {
                        Text("Sign out").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Parent controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
            }
            .task {
                for action in ParentControlsPresentation.appearActions {
                    switch action {
                    case .syncDeletionProtection:
                        screenTime.syncDeletionProtectionToManagedSettings()
                    case .refreshNotificationStatus:
                        await refreshNotifStatus()
                    }
                }
            }
            .fullScreenCover(isPresented: $showLockList) {
                NavigationStack {
                    AppControlsV2View(childDeviceID: childDeviceID)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showLockList = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showScreenTimeCapture) {
                NavigationStack {
                    ScrollView {
                        // Same component the kid-home one-time card uses; onDone
                        // dismisses the sheet once the selection is saved.
                        ScreenTimeCaptureView { showScreenTimeCapture = false }
                            .padding(20)
                    }
                    .background(EvlinKidColors.surface2.ignoresSafeArea())
                    .navigationTitle("Screen Time Tracking")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showScreenTimeCapture = false }
                        }
                    }
                }
            }
            .alert("Sign out this device?", isPresented: $showSignOutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { onSignOut() }
            } message: {
                Text("It resets this phone back to setup. Your family link isn't removed — a parent can remove this child from the parent app if needed.")
            }
        }
    }

    private func rowLabel(icon: String, title: String, subtitle: String? = nil, trailingChevron: Bool = false, badgeColor: Color? = nil) -> some View {
        HStack(spacing: 12) {
            if let badgeColor {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(badgeColor))
            } else {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 26)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if trailingChevron { Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .foregroundStyle(.green)
    }

    private func refreshNotifStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifAuthorized = settings.authorizationStatus == .authorized
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    Task { await refreshNotifStatus() }
                }
            case .denied:
                DispatchQueue.main.async {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            default:
                Task { await refreshNotifStatus() }
            }
        }
    }
}
