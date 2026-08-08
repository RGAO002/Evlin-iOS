import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity
import AVFoundation
import UserNotifications

/// Pure, testable mapping for child create/edit/delete. Kept free of SwiftUI
/// so it can be unit-tested without a view host. The view layer (below) calls
/// these then performs the async APIClient round-trip + FamilyStore refresh.
enum ChildCRUDMapper {
    static func createBody(name: String, age: Int, referenceYear: Int) -> CreateChildBody {
        CreateChildBody(
            display_name: name,
            birth_year: referenceYear - age,
            gender: nil,
            child_device_id: nil
        )
    }

    static func updateBody(name: String, age: Int, referenceYear: Int) -> UpdateChildBody {
        UpdateChildBody(
            display_name: name,
            birth_year: referenceYear - age,
            gender: nil,
            avatar_kind: nil,
            avatar_value: nil,
            avatar_color: nil
        )
    }

    /// Human-readable message for a delete failure. The backend returns 409
    /// when a child still has a linked device (DELETE /family/children/{id}).
    static func deleteErrorMessage(for error: Error) -> String {
        if case APIError.serverError(409) = error {
            return "This child still has a paired device. Unpair the device before deleting."
        }
        return "Couldn't delete this child. \(error.localizedDescription)"
    }

    static func saveErrorMessage(for error: Error) -> String {
        "Couldn't save. \(error.localizedDescription)"
    }
}

enum ParentSettingsPresentation {
    enum NotificationPermissionAction: Equatable {
        case requestAuthorization
        case openSystemSettings
        case setLocalPreference
        case refreshStatus
    }

    static let defaultNotificationToggleIDs = [
        "kid_requests",
        "reflection_completions",
        "kid_nudges",
    ]

    static let parentPushMasterMuteType = "*"

    static let parentAccentHexOptions = [
        "#24324A",
        "#2E7D32",
        "#7C6FF7",
        "#EF6C00",
        "#0F766E",
        "#BE185D",
        "#2563EB",
        "#6B7280",
    ]

    static let parentProfileHeroAccentHexOptions = parentAccentHexOptions

    static let childProfileHeroAccentHexOptions = parentProfileHeroAccentHexOptions

    static func versionDisplay(shortVersion: String?, build: String?) -> String {
        let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return "—" }

        let buildNumber = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return buildNumber.isEmpty ? version : "\(version) (\(buildNumber))"
    }

    static func childrenDevicesSummary(childCount: Int, deviceCount: Int) -> String {
        let childCopy = "\(childCount) \(childCount == 1 ? "child" : "children")"
        let deviceCopy = "\(deviceCount) \(deviceCount == 1 ? "child device" : "child devices")"
        return "\(childCopy) · \(deviceCopy)"
    }

    static func coParentValue(coParentCount: Int) -> String {
        guard coParentCount > 0 else { return "None" }
        return "\(coParentCount) adults"
    }

    /// Removing the device whose detail is currently displayed must pop one
    /// level back to that child's device list. An unrelated detail selection is
    /// never changed.
    static func deviceDetailSelectionAfterRemoval(
        selectedDeviceID: String?,
        removedDeviceID: String
    ) -> String? {
        selectedDeviceID == removedDeviceID ? nil : selectedDeviceID
    }

    static func latestDevice(
        initial: EnrolledDeviceDTO,
        refreshedDevices: [EnrolledDeviceDTO]
    ) -> EnrolledDeviceDTO {
        refreshedDevices.first(where: { $0.device_id == initial.device_id }) ?? initial
    }

    static func parentRootAvatarURL(_ signedURL: String?) -> String? {
        signedURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func childSettingsAvatarURL(_ signedURL: String?) -> String? {
        signedURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func notificationStatusCopy(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .notDetermined: return "Not Asked Yet"
        case .provisional: return "Provisional"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }

    static func notificationPermissionAction(
        status: UNAuthorizationStatus,
        wantsEnabled: Bool
    ) -> NotificationPermissionAction {
        if wantsEnabled {
            switch status {
            case .notDetermined:
                return .requestAuthorization
            case .denied:
                return .openSystemSettings
            case .authorized, .provisional, .ephemeral:
                return .setLocalPreference
            @unknown default:
                return .refreshStatus
            }
        }

        return .openSystemSettings
    }
}

/// A tagged NavigationLink can clear its selection without dismissing a
/// destination that is already on the stack. The open detail owns the final
/// native dismissal after its device was removed.
enum DeviceDetailDismissalPolicy {
    static func shouldDismiss(selectedDeviceID: String?, detailDeviceID: String) -> Bool {
        selectedDeviceID != detailDeviceID
    }
}

/// Keeps identity teardown out of the live Settings hierarchy. Clearing the
/// session while this large view is mounted can make SwiftUI recursively
/// rebuild it while the app root is changing.
struct HomeSettingsSessionExitCoordinator {
    private var exitPending = false

    mutating func requestExit(dismiss: () -> Void) {
        guard !exitPending else { return }
        exitPending = true
        dismiss()
    }

    mutating func completeAfterDismissal(teardown: () -> Void) {
        guard exitPending else { return }
        exitPending = false
        teardown()
    }
}

private struct DeviceDetailDismissalHost<Content: View>: View {
    @Binding private var selectedDeviceID: String?
    private let detailDeviceID: String
    private let content: Content
    @Environment(\.dismiss) private var dismiss

    init(
        selectedDeviceID: Binding<String?>,
        detailDeviceID: String,
        @ViewBuilder content: () -> Content
    ) {
        _selectedDeviceID = selectedDeviceID
        self.detailDeviceID = detailDeviceID
        self.content = content()
    }

    var body: some View {
        content.onChange(of: selectedDeviceID) { newValue in
            if DeviceDetailDismissalPolicy.shouldDismiss(
                selectedDeviceID: newValue,
                detailDeviceID: detailDeviceID
            ) {
                dismiss()
            }
        }
    }
}

struct HomeSettingsSheet: View {
    @EnvironmentObject var apiClient: APIClient
    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(FamilyStore.self) private var familyStore
    @Environment(\.scenePhase) private var scenePhase
    var onClose: () -> Void

    @AppStorage("parentName") private var parentName: String = ""
    @AppStorage("childName") private var childName: String = ""
    @AppStorage("appMode") private var appMode: String = ""
    @AppStorage("evlin.familyID") private var familyID: String = ""
    @AppStorage("evlin.parentDeviceID") private var parentDeviceID: String = ""
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""

    /// Seeded from `FamilyStore.childProfiles` (real GET /family data) in
    /// `.onAppear`. Kept as local state because add/edit/delete mutate the list
    /// in place during the session.
    @State private var children: [ChildProfile] = []
    @State private var editing: ChildProfile? = nil

    @State private var serverURL: String = ""
    @State private var childOpError: String? = nil
    @State private var isChildOpInFlight: Bool = false
    @State private var devicePendingRemoval: DeviceRemovalTarget? = nil
    @State private var removingDeviceID: String? = nil
    @State private var deviceRemovalError: String? = nil
    @State private var selectedDeviceDetailID: String? = nil
    @State private var revealedParentPINDeviceIDs: Set<String> = []
    @State private var clearingParentPINDeviceIDs: Set<String> = []
    @State private var parentPINClearTarget: DeviceRemovalTarget? = nil
    @State private var parentPINClearError: String? = nil
    /// HP-14: baseline for the "Parent name" field captured on appear, so we
    /// only PUT /me/profile when the user actually edited the name in THIS
    /// session (a stale legacy @AppStorage value must not silently rename
    /// the parent on Done).
    @State private var parentNameAtOpen: String = ""
    @State private var parentNameError: String? = nil
    @State private var isSavingParentName: Bool = false
    @State private var parentPickedAvatar: UIImage? = nil
    @State private var parentAvatarURL: String? = nil
    @State private var parentAvatarError: String? = nil
    @State private var isUploadingParentAvatar = false
    @State private var selectedParentAccentHex = ParentSettingsPresentation.parentAccentHexOptions[0]
    @State private var parentAccentError: String? = nil
    @State private var isSavingParentAccent = false
    @State private var childPickedAvatarByID: [String: UIImage] = [:]
    @State private var childAvatarURLByID: [String: String] = [:]
    @State private var childAvatarErrorByID: [String: String] = [:]
    @State private var uploadingChildAvatarIDs: Set<String> = []
    @State private var selectedChildAccentHexByID: [String: String] = [:]
    @State private var childAccentErrorByID: [String: String] = [:]
    @State private var savingChildAccentIDs: Set<String> = []
    @State private var isPickerPresented = false
    @State private var showPINGate = false
    @State private var showAddApp = false
    /// Data-export (§5.4(a)) state.
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportFileURL: URL?
    @State private var showExportShare = false
    /// Permanent-deletion confirmation state (typed DELETE + in-flight guard).
    @State private var deleteConfirmText = ""
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var showAddList = false
    @State private var showLockListGate = false
    @State private var showLockListManager = false
    @State private var showAddChildPairing = false
    @State private var showAddDevicePairing = false
    @State private var showParentProfileMenu = false
    @State private var showDebugSettings = false
    @State private var showNotificationsMenu = false
    @State private var addDevicePairingKidName = ""
    /// Settings only presents a scanner after a child has been selected. A
    /// non-optional target makes it impossible for this path to mint a
    /// `new_child` invite by accident.
    @State private var addDeviceTargetChildID: UUID? = nil
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingNotificationSystemSettingsIntent: Bool? = nil
    @State private var pendingGatedAction: GatedAction?
    @State private var sessionExitCoordinator = HomeSettingsSessionExitCoordinator()

    @AppStorage("evlin.settings.notifications.enabled") private var notifyPushEnabled: Bool = true
    @AppStorage("evlin.settings.notifications.kidRequests") private var notifyKidRequests: Bool = true
    @AppStorage("evlin.settings.notifications.reflectionCompletions") private var notifyReflectionCompletions: Bool = true
    @AppStorage("evlin.settings.notifications.kidNudges") private var notifyKidNudges: Bool = true
    @AppStorage("evlin.settings.notifications.weeklySummary") private var notifyWeeklySummary: Bool = false

    @AppStorage("evlin.protectionMode") private var savedProtectionMode: String = "std"

    /// Bumps SwiftUI redraw after camera permission callbacks.
    @State private var cameraPermissionFreshness: Int = 0

    /// Family protection mode mirror — synced from backend on appear, PUT-back when the segmented control changes.
    @State private var protectionMode: String = "std"
    @State private var protectionModeStatus: String = ""

    private enum GatedAction {
        case addApp
        case addList
    }

    private struct DeviceRemovalTarget: Identifiable {
        let child: ChildProfile
        let device: EnrolledDeviceDTO
        var id: String { device.device_id }
    }

    var body: some View {
        NavigationStack {
            Form {
                settingsRootContent

                #if DEBUG
                Section("Developer") {
                    Button {
                        showDebugSettings = true
                    } label: {
                        settingsRow(
                            title: "Developer Tools",
                            subtitle: "IDs, environment, test notifications",
                            systemImage: "hammer",
                            pill: "DEBUG",
                            pillTone: .warning,
                            accent: .evPrimary
                        )
                    }

                    Text("This entry is visible only in development builds. Production hides it entirely.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                #endif

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showParentProfileMenu) {
                parentProfileMenu
            }
            .sheet(isPresented: $showExportShare) {
                if let exportFileURL {
                    DataExportShareSheet(fileURL: exportFileURL)
                }
            }
            .navigationDestination(isPresented: $showNotificationsMenu) {
                notificationsMenu
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !serverURL.isEmpty {
                            apiClient.saveServerURL(serverURL)
                        }
                        // HP-14: commit a parent-name edit before closing.
                        // On failure the sheet stays open so the error is
                        // actually visible (revert the field or retry).
                        Task {
                            if await saveParentNameIfChanged() {
                                onClose()
                            }
                        }
                    }
                }
            }
            .onAppear {
                // Seed the editable children list from the live FamilyStore
                // (real GET /family data) instead of the retired mock. Only
                // seed once so in-session add/edit/delete aren't clobbered.
                if children.isEmpty {
                    children = familyStore.childProfiles
                }
                // HP-14: the server display_name is the source of truth
                // (HomeView prefers it over the local @AppStorage shadow) —
                // seed the field from it so the user edits what they
                // actually see, and capture the baseline so Done only PUTs
                // names changed in this session.
                if let serverName = familyStore.selfParent?.display_name,
                   !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parentName = serverName
                }
                parentNameAtOpen = parentName
                serverURL = apiClient.baseURL
                seedParentProfilePresentation()
                screenTimeManager.refreshAuthorizationStatus()
                refreshNotificationAuthorizationStatus()
                Task {
                    await refreshParentNotificationPreferences()
                    AppDelegate.uploadCachedAPNsTokenIfPossible(using: apiClient)
                }
                // Sync DEBUG protection-mode picker from backend so the
                // segmented control reflects truth, not the @State default.
                if let famID = UUID(uuidString: familyID) {
                    Task {
                        if let m = try? await apiClient.getProtectionMode(familyID: famID) {
                            await MainActor.run {
                                protectionMode = m
                                UserDefaults.standard.set(m, forKey: "evlin.protectionMode")
                            }
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await reconcileNotificationStateAfterSystemSettings()
                }
            }
            .sheet(item: $editing) { child in
                ChildEditSheet(child: child) { name, age in
                    Task { await saveEditedChild(id: child.id, name: name, age: age) }
                }
            }
            #if DEBUG
            .sheet(isPresented: $showDebugSettings) {
                NavigationStack {
                    debugSettingsMenu
                }
            }
            #endif
            .fullScreenCover(isPresented: $showAddDevicePairing) {
                addDevicePairingCover
            }
            .fullScreenCover(isPresented: $showAddChildPairing) {
                addChildPairingCover
            }
            .sheet(isPresented: $showPINGate) {
                EvlinPINGateView(
                    store: .shared,
                    onUnlocked: {
                        showPINGate = false
                        switch pendingGatedAction {
                        case .addApp:
                            showAddApp = true
                        case .addList:
                            showAddList = true
                        case .none:
                            break
                        }
                        pendingGatedAction = nil
                    },
                    onCancel: {
                        showPINGate = false
                        pendingGatedAction = nil
                    }
                )
            }
            .sheet(isPresented: $showLockListGate) {
                EvlinPINGateView(
                    store: .shared,
                    onUnlocked: {
                        showLockListGate = false
                        showLockListManager = true
                    },
                    onCancel: {
                        showLockListGate = false
                    }
                )
            }
            .sheet(isPresented: $showLockListManager) {
                if let familyID = UUID(uuidString: familyID),
                   let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        LockListManagerView(
                            familyID: familyID,
                            childDeviceID: childID
                        )
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing family / child device ID).")
                        .padding()
                }
            }
            .sheet(isPresented: $showAddApp) {
                if let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        AddAppFlowView(childDeviceID: childID) { _ in
                            showAddApp = false
                        }
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing child device ID).")
                        .padding()
                }
            }
            .sheet(isPresented: $showAddList) {
                if let familyID = UUID(uuidString: familyID),
                   let childID = UUID(uuidString: childDeviceID) {
                    NavigationStack {
                        SavedListPickerView(
                            familyID: familyID,
                            owningDeviceID: childID,
                            mode: "child_device"
                        ) { _ in
                            showAddList = false
                        }
                        .environmentObject(apiClient)
                    }
                } else {
                    Text("Pair this device first (missing family / child device ID).")
                        .padding()
                }
            }
            .confirmationDialog(
                "Remove \(devicePendingRemoval.map { deviceDisplayName($0.device) } ?? "device")?",
                isPresented: Binding(
                    get: { devicePendingRemoval != nil },
                    set: { if !$0 { devicePendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Device", role: .destructive) {
                    guard let target = devicePendingRemoval else { return }
                    Task { await removeDevice(target) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the device from this family. Its Evlin limits and setup are cleared the next time it opens Evlin. Your child and the device's past history stay in your account.")
            }
            .alert(
                "Couldn’t Remove Device",
                isPresented: Binding(
                    get: { deviceRemovalError != nil },
                    set: { if !$0 { deviceRemovalError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceRemovalError ?? "")
            }
        }
        .onDisappear {
            sessionExitCoordinator.completeAfterDismissal {
                tearDownLocalSession()
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var addDevicePairingCover: some View {
        if let targetChildID = addDeviceTargetChildID {
            ParentAddDevicePairingFlow(
                kidName: addDevicePairingKidName,
                targetChildProfileID: targetChildID,
                apiClient: apiClient,
                onDone: {
                    showAddDevicePairing = false
                    addDevicePairingKidName = ""
                    addDeviceTargetChildID = nil
                    Task {
                        await familyStore.refresh()
                        children = familyStore.childProfiles
                    }
                },
                onCancel: {
                    showAddDevicePairing = false
                    addDevicePairingKidName = ""
                    addDeviceTargetChildID = nil
                }
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var addChildPairingCover: some View {
        ParentNewChildPairingFlow(
            apiClient: apiClient,
            onDone: {
                showAddChildPairing = false
                Task {
                    await familyStore.refresh()
                    children = familyStore.childProfiles
                }
            },
            onCancel: {
                showAddChildPairing = false
            }
        )
    }

    @ViewBuilder
    private var settingsRootContent: some View {
        Section {
            Button {
                showParentProfileMenu = true
            } label: {
                settingsProfileCard(
                    title: parentDisplayName,
                    subtitle: "Parent account · \(familyDisplayName)",
                    initials: parentInitials,
                    avatarURL: ParentSettingsPresentation.parentRootAvatarURL(parentAvatarURL)
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

        Section("Family") {
            NavigationLink {
                childrenDevicesMenu
            } label: {
                settingsRow(
                    title: "Children & Devices",
                    subtitle: childrenDevicesSummary,
                    systemImage: "person",
                    value: "\(children.count) \(children.count == 1 ? "child" : "children")",
                    accent: .evPrimary
                )
            }

            NavigationLink {
                AliasManagementView()
                    .environmentObject(apiClient)
            } label: {
                settingsRow(
                    title: "Manage Aliases",
                    subtitle: "Family app names and command phrases",
                    systemImage: "tag",
                    value: "Apps",
                    accent: .evPrimary
                )
            }

            NavigationLink {
                coParentsMenu
            } label: {
                settingsRow(
                    title: "Co-parents",
                    subtitle: coParentSummary,
                    systemImage: "person.2",
                    value: coParentValue,
                    accent: .evSecondary
                )
            }

            Button {
                showAddChildPairing = true
            } label: {
                settingsRow(
                    title: "Add Child",
                    subtitle: "Create their profile, then pair a device",
                    systemImage: "plus",
                    accent: .evPrimary
                )
            }
        }

        Section("Notifications") {
            settingsNavigableToggleRow(
                title: "Push Notifications",
                subtitle: notificationRootSubtitle,
                systemImage: "bell",
                isOn: notificationPermissionBinding,
                accent: .evSecondary,
                navigate: { showNotificationsMenu = true }
            )
        }

        Section("About") {
            Button {
                // Clearing every tour flag re-arms all first-visit tours:
                // Home replays immediately (ParentRootView observes its
                // flag); each other tab replays on its next visit. Close
                // the sheet so the Home tour is instantly visible.
                for key in ["parentHomeTourSeen", "parentCalendarTourSeen",
                            "parentChatTourSeen", "parentLibraryTourSeen",
                            "parentInsightsTourSeen", "parentProfileTourSeen",
                            "parentDeviceLimitsTourSeen"] {
                    UserDefaults.standard.set(false, forKey: key)
                }
                onClose()
            } label: {
                settingsRow(
                    title: "Replay the tours",
                    subtitle: "Re-run each tab's quick intro",
                    systemImage: "sparkles",
                    accent: .evPrimary
                )
            }

            settingsRow(
                title: "Version",
                subtitle: "",
                systemImage: "info.circle",
                value: appVersionDisplay,
                accent: .evPrimary
            )

            NavigationLink {
                privacyTermsMenu
            } label: {
                settingsRow(
                    title: "Privacy & Terms",
                    subtitle: "Policies and service terms",
                    systemImage: "shield",
                    accent: .evPrimary
                )
            }

            // Beta Participation Agreement §5.4(a): the parent can review the
            // data Evlin holds. Served straight from the app so the promise
            // doesn't depend on someone running a query by hand.
            Button {
                Task { await exportMyData() }
            } label: {
                settingsRow(
                    title: exporting ? "Preparing…" : "Download my data",
                    subtitle: "Everything Evlin stores for your family, as JSON",
                    systemImage: "square.and.arrow.down",
                    accent: .evPrimary,
                    disabled: exporting
                )
            }
            .disabled(exporting)

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
            }
        }
    }

    @ViewBuilder
    private var childrenDevicesMenu: some View {
        Form {
            settingsHeroNote(
                title: "Family devices are scoped by child.",
                message: "Choose which kid/device you are managing. App lists and controls live under the child device, not on the parent phone."
            )

            Section("Children") {
                if children.isEmpty {
                    Text("No children yet.")
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }

                ForEach(children) { child in
                    NavigationLink {
                        childDetailMenu(child)
                    } label: {
                        settingsChildRow(child)
                    }
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { children[$0] }
                    Task { await deleteChildren(toDelete) }
                }

                if let childOpError {
                    Text(childOpError)
                        .font(.caption)
                        .foregroundStyle(Color.evError)
                }
            }

            Section("Setup") {
                Button {
                    showAddChildPairing = true
                } label: {
                    settingsRow(
                        title: "Add Child",
                        subtitle: "Create their profile, then pair a device",
                        systemImage: "qrcode.viewfinder",
                        accent: .evPrimary
                    )
                }
            }
        }
        .navigationTitle("Children & Devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var notificationsMenu: some View {
        Form {
            settingsHeroNote(
                title: "Parent-side permission.",
                message: "This replaces Screen Time on the parent phone. The parent mainly needs APNs readiness for kid requests, completions, and alerts."
            )

            Section("Permission") {
                settingsToggleRow(
                    title: "Push Notifications",
                    subtitle: "System permission for parent alerts",
                    systemImage: "bell",
                    isOn: notificationPermissionBinding,
                    accent: .evSecondary
                )

                Button {
                    Task { await handleNotificationPermissionTap() }
                } label: {
                    settingsRow(
                        title: notificationActionTitle,
                        subtitle: "Banners, sounds, badges",
                        systemImage: "gearshape",
                        accent: .evPrimary
                    )
                }
                .buttonStyle(.plain)
            }

            Section {
                Toggle(isOn: $notifyKidRequests) {
                    settingsRow(
                        title: "Kid requests",
                        subtitle: "Bypass requests, help requests",
                        systemImage: "bell",
                        accent: .evSecondary
                    )
                }
                Toggle(isOn: $notifyReflectionCompletions) {
                    settingsRow(
                        title: "Reflection completions",
                        subtitle: "Notify when a kid finishes",
                        systemImage: "checkmark.circle",
                        accent: .evSecondary
                    )
                }
                Toggle(isOn: $notifyKidNudges) {
                    settingsRow(
                        title: "Nudges from kid device",
                        subtitle: "Kid asks parent to review",
                        systemImage: "hand.raised",
                        accent: .evSecondary
                    )
                }
                Toggle(isOn: $notifyWeeklySummary) {
                    settingsRow(
                        title: "Weekly summary",
                        subtitle: "Optional progress digest",
                        systemImage: "calendar",
                        accent: .evPrimary
                    )
                }
            } header: {
                Text("Alert Types")
            } footer: {
                Text("These switches are local presentation settings for now; backend routing preferences can be wired here when the endpoint exists.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var coParentsMenu: some View {
        Form {
            settingsHeroNote(
                title: "Family-level access belongs here.",
                message: "Co-parents are not connected to app controls. They manage people, alerts, approvals, and family visibility."
            )

            Section("Parents") {
                if coParents.isEmpty {
                    settingsRow(
                        title: "No co-parents yet",
                        subtitle: "Invite another parent or caregiver when needed",
                        systemImage: "person.2",
                        value: "None",
                        accent: .evSecondary
                    )
                }

                ForEach(coParents) { parent in
                    settingsRow(
                        title: parent.display_name,
                        subtitle: "Co-parent",
                        systemImage: "person.2",
                        accent: .evSecondary
                    )
                }

                NavigationLink {
                    OwnerInviteApprovalView()
                        .environmentObject(apiClient)
                } label: {
                    settingsRow(
                        title: "Invite Co-parent",
                        subtitle: "Create and share an invite code",
                        systemImage: "plus",
                        accent: .evPrimary
                    )
                }
            }

            Section {
                settingsRow(title: "Can receive kid requests", subtitle: "Family notification access", systemImage: "checkmark.circle", value: "On", accent: .evSecondary)
                settingsRow(title: "Can approve tasks", subtitle: "Approval permissions", systemImage: "checkmark.circle", value: "On", accent: .evSecondary)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Permission editing is not wired yet; current rows describe the intended family-level model.")
            }
        }
        .navigationTitle("Co-parents")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var parentProfileMenu: some View {
        Form {
            Section {
                parentProfileHero
            }
            .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            Section("Profile") {
                HStack(spacing: 12) {
                    settingsIconChip("pencil", accent: .evPrimary)
                    Text("Display Name")
                        .font(.custom("Inter", size: 15).weight(.semibold))
                        .foregroundStyle(Color.evOnSurface)
                    Spacer()
                    TextField("Parent name", text: $parentName)
                        .font(.custom("Inter", size: 13).weight(.medium))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { _ = await saveParentNameIfChanged() } }
                }
                .padding(.vertical, 4)

                settingsRow(
                    title: "Email",
                    subtitle: "Not exposed by current profile payload",
                    systemImage: "at",
                    value: "Not wired",
                    accent: .evPrimary
                )

                if let parentNameError {
                    Text(parentNameError)
                        .font(.caption)
                        .foregroundStyle(Color.evError)
                }
            }

            Section("Session") {
                NavigationLink {
                    signOutMenu
                } label: {
                    settingsRow(
                        title: "Sign Out",
                        subtitle: "Remove this parent session from this device",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        accent: .evError,
                        danger: true
                    )
                }

                NavigationLink {
                    deleteAccountMenu
                } label: {
                    settingsRow(
                        title: "Delete Account",
                        subtitle: "Permanently delete your account and its data",
                        systemImage: "trash",
                        accent: .evError,
                        danger: true
                    )
                }
            }
        }
        .navigationTitle("Parent Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Permanent account deletion. Deliberately a separate screen from Sign
    /// Out: it names exactly what goes, warns about the kid device (whose
    /// deletion protection can only be lifted while the app can still reach
    /// it), and requires typing DELETE so it can't be triggered by a stray tap.
    @ViewBuilder
    private var deleteAccountMenu: some View {
        Form {
            settingsHeroNote(
                title: isLastParent
                    ? "Delete your account and this family?"
                    : "Delete your parent account?",
                message: isLastParent
                    ? "You're the only parent, so the whole family goes with you: every child profile, task, screen-time record, and app rule. This cannot be undone."
                    : "Your parent account, profile, and personal data are removed. The family, the children, and the other parents stay."
            )

            Section("Before you delete") {
                deleteChecklistRow(
                    icon: "iphone.slash",
                    text: "On \(kidDeviceLabel)'s phone, open Evlin and sign out first. Until it hears about the deletion, that phone can't remove any app — including Evlin."
                )
                deleteChecklistRow(
                    icon: "clock.arrow.circlepath",
                    text: "If you can't sign out there now, just open Evlin on that phone once after deleting — it releases everything automatically."
                )
                deleteChecklistRow(
                    icon: "exclamationmark.triangle",
                    text: "Signing in again later creates a brand-new account. Nothing is restored."
                )
            }

            Section("Type DELETE to confirm") {
                TextField("DELETE", text: $deleteConfirmText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    // `.characters` only sets the keyboard's default shift
                    // state — a hardware keyboard, or one tap on shift, still
                    // types lowercase. Fold the binding itself so what the
                    // parent sees always matches the word they must type.
                    .onChange(of: deleteConfirmText) { _, new in
                        let folded = new.uppercased()
                        if folded != new { deleteConfirmText = folded }
                    }

                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(Color.evError)
                }

                Button(role: .destructive) {
                    Task { await performDeleteAccount() }
                } label: {
                    HStack {
                        settingsRow(
                            title: deleting ? "Deleting…" : "Delete Account",
                            subtitle: "This cannot be undone",
                            systemImage: "trash",
                            accent: .evError,
                            danger: true,
                            disabled: !canConfirmDelete
                        )
                        if deleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canConfirmDelete || deleting)
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Fetch the export and hand it to a share sheet. Written to a temp file
    /// first so the user can save it to Files / mail it, rather than staring
    /// at JSON in a text view.
    @MainActor
    private func exportMyData() async {
        guard !exporting else { return }
        exporting = true
        exportError = nil
        defer { exporting = false }
        do {
            let data = try await apiClient.fetchDataExport()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("evlin-data-export.json")
            try data.write(to: url, options: .atomic)
            exportFileURL = url
            showExportShare = true
        } catch {
            exportError = "Couldn't prepare your data: \(error.localizedDescription)"
        }
    }

    private var canConfirmDelete: Bool {
        deleteConfirmText.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
    }

    /// Other non-deleted parents in the family decide whether this deletion
    /// takes the family with it. Mirrors the backend's co-parent branch.
    private var isLastParent: Bool {
        familyStore.parents.count <= 1
    }

    private var kidDeviceLabel: String {
        familyStore.childProfiles.first?.name ?? "your kid"
    }

    @ViewBuilder
    private func deleteChecklistRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evError)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .padding(.vertical, 2)
    }

    /// Server first, local teardown second. If the request fails we keep every
    /// local credential so the parent can retry — wiping first would strand a
    /// live server-side account with no way back in.
    @MainActor
    private func performDeleteAccount() async {
        guard canConfirmDelete, !deleting else { return }
        deleting = true
        deleteError = nil
        do {
            try await apiClient.deleteAccount()
        } catch {
            deleting = false
            deleteError = "Couldn't delete the account: \(error.localizedDescription). Nothing was removed — check your connection and try again."
            return
        }
        // Server confirmed. Dismiss the live Settings hierarchy before
        // clearing @AppStorage and routing the app back to onboarding.
        requestSessionExit()
    }

    @ViewBuilder
    private var signOutMenu: some View {
        Form {
            settingsHeroNote(
                title: "Sign out of this parent phone?",
                message: "Family data stays in the account. This device stops receiving parent notifications until signed in again."
            )

            Section("Confirm") {
                Button(role: .destructive) {
                    requestSessionExit()
                } label: {
                    settingsRow(
                        title: "Sign Out",
                        subtitle: "Return this device to onboarding",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        accent: .evError,
                        danger: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Sign Out")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var aboutMenu: some View {
        Form {
            Section("App") {
                settingsRow(
                    title: "Version",
                    subtitle: "CFBundleShortVersionString + CFBundleVersion",
                    systemImage: "info.circle",
                    value: appVersionDisplay,
                    accent: .evPrimary
                )
                settingsRow(
                    title: "Build Source",
                    subtitle: "Read from app bundle at runtime",
                    systemImage: "checkmark.seal",
                    value: "Xcode",
                    accent: .evSecondary
                )
            }

            Section("Legal") {
                NavigationLink {
                    placeholderMenu(
                        title: "Privacy Policy",
                        message: "The in-app privacy policy page is not wired yet."
                    )
                } label: {
                    settingsRow(title: "Privacy Policy", subtitle: "Coming soon", systemImage: "hand.raised", accent: .evPrimary)
                }
                NavigationLink {
                    placeholderMenu(
                        title: "Terms of Service",
                        message: "The in-app terms page is not wired yet."
                    )
                } label: {
                    settingsRow(title: "Terms of Service", subtitle: "Coming soon", systemImage: "doc.text", accent: .evPrimary)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var privacyTermsMenu: some View {
        Form {
            Section("Legal") {
                NavigationLink {
                    placeholderMenu(
                        title: "Privacy Policy",
                        message: "The in-app privacy policy page is not wired yet."
                    )
                } label: {
                    settingsRow(title: "Privacy Policy", subtitle: "Coming soon", systemImage: "hand.raised", accent: .evPrimary)
                }
                NavigationLink {
                    placeholderMenu(
                        title: "Terms of Service",
                        message: "The in-app terms page is not wired yet."
                    )
                } label: {
                    settingsRow(title: "Terms of Service", subtitle: "Coming soon", systemImage: "doc.text", accent: .evPrimary)
                }
            }
        }
        .navigationTitle("Privacy & Terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func placeholderMenu(title: String, message: String) -> some View {
        Form {
            settingsHeroNote(title: title, message: message)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func childDetailMenu(_ child: ChildProfile) -> some View {
        let displayChild = currentChild(for: child)
        return Form {
            Section {
                childProfileHero(displayChild)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            Section("Devices") {
                let devices = backendChild(for: displayChild)?.devices ?? []
                if devices.isEmpty {
                    settingsRow(
                        title: "No devices enrolled yet",
                        subtitle: "Use Add Device below when the first device is ready",
                        systemImage: "iphone.slash",
                        accent: .evOutline,
                        disabled: true
                    )
                }
                ForEach(devices) { device in
                    NavigationLink(
                        destination: DeviceDetailDismissalHost(
                            selectedDeviceID: $selectedDeviceDetailID,
                            detailDeviceID: device.device_id
                        ) {
                            deviceDetailMenu(child: displayChild, device: device)
                        },
                        tag: device.device_id,
                        selection: $selectedDeviceDetailID
                    ) {
                        settingsRow(
                            title: deviceDisplayName(device),
                            subtitle: deviceStatusLine(device),
                            systemImage: deviceIcon(device),
                            value: device.is_self ? "Primary" : deviceKind(device),
                            accent: device.online ? .evSecondary : .evOutline
                        )
                    }
                }
            }

            Section("Profile") {
                Button {
                    editing = displayChild
                } label: {
                    settingsRow(
                        title: "Child Profile",
                        subtitle: "Name, age, avatar",
                        systemImage: "person",
                        accent: .evPrimary
                    )
                }
                .buttonStyle(.plain)

                Button {
                    // The target rides on the invite, so the kid device is
                    // told whose device it is becoming and never asked for a
                    // name it already has.
                    addDeviceTargetChildID = UUID(uuidString: displayChild.id)
                    addDevicePairingKidName = displayChild.name
                    showAddDevicePairing = true
                } label: {
                    settingsRow(
                        title: "Add/Recover Device for \(displayChild.name)",
                        subtitle: "Show a code for the new or returning device to scan",
                        systemImage: "plus",
                        value: "",
                        accent: .evSecondary
                    )
                }
                .buttonStyle(.plain)
                .disabled(UUID(uuidString: displayChild.id) == nil)
            }
        }
        .navigationTitle(displayChild.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deviceDetailMenu(
        child: ChildProfile,
        device initialDevice: EnrolledDeviceDTO
    ) -> some View {
        let device = ParentSettingsPresentation.latestDevice(
            initial: initialDevice,
            refreshedDevices: backendChild(for: child)?.devices ?? []
        )
        return Form {
            settingsHeroNote(
                title: deviceDisplayName(device),
                message: "Device-level state reported by \(child.name)'s phone."
            )

            #if DEBUG
            Section("Status") {
                settingsRow(
                    title: "Connection",
                    subtitle: device.last_seen_at.map { "Last seen \($0)" } ?? "Last heartbeat not available",
                    systemImage: device.online ? "dot.radiowaves.left.and.right" : "wifi.slash",
                    pill: device.online ? "Online" : "Offline",
                    pillTone: device.online ? .success : .warning,
                    accent: device.online ? .evSecondary : .evOutline
                )
                settingsRow(
                    title: "Kid App Notifications",
                    subtitle: "Requests and completion events can reach parent",
                    systemImage: "bell",
                    pill: "Ready",
                    pillTone: .success,
                    accent: .evSecondary
                )
            }
            #endif

            Section("Security") {
                let row = ParentPINRow.display(
                    status: device.parent_pin_status ?? "not_set",
                    pin: device.parent_pin,
                    kidName: child.name
                )
                let revealed = revealedParentPINDeviceIDs.contains(device.device_id)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.evSecondaryContainer)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: "lock")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.evSecondary)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.evLabelLarge)
                                .foregroundStyle(Color.evPrimary)
                            Text(row.subtitle)
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    // The value gets its own monospaced field rather than a
                    // trailing label: a parent reads these digits off the screen
                    // and types them on another phone, so even spacing and a
                    // deliberate reveal beat a cramped right-aligned row.
                    if let pin = row.value {
                        HStack {
                            Text(revealed ? pin : String(repeating: "•", count: pin.count))
                                .font(.system(size: 17, weight: .medium, design: .monospaced))
                                .tracking(revealed ? 4 : 2)
                                .foregroundStyle(Color.evPrimary)
                            Spacer(minLength: 0)
                            Button {
                                if revealed {
                                    revealedParentPINDeviceIDs.remove(device.device_id)
                                } else {
                                    revealedParentPINDeviceIDs.insert(device.device_id)
                                }
                            } label: {
                                Image(systemName: revealed ? "eye.slash" : "eye")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(revealed ? "Hide PIN" : "Show PIN")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .fill(Color.evSurfaceContainerLow)
                        )
                    }
                }
                .padding(.vertical, 4)
                if row.canClear {
                    Button("Clear PIN", role: .destructive) {
                        parentPINClearTarget = DeviceRemovalTarget(child: child, device: device)
                    }
                    .disabled(clearingParentPINDeviceIDs.contains(device.device_id))
                }
                if clearingParentPINDeviceIDs.contains(device.device_id) {
                    HStack {
                        ProgressView()
                        Text("Clearing PIN")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    devicePendingRemoval = DeviceRemovalTarget(child: child, device: device)
                } label: {
                    if removingDeviceID == device.device_id {
                        HStack {
                            ProgressView()
                            Text("Removing Device")
                        }
                    } else {
                        Label("Remove Device", systemImage: "trash")
                    }
                }
                .disabled(removingDeviceID != nil)
            } footer: {
                Text("This removes only this device. The child profile and other enrolled devices stay in place.")
            }
        }
        .navigationTitle("Child Device")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: initialDevice.device_id) {
            await familyStore.refresh()
            children = familyStore.childProfiles
        }
        .confirmationDialog(
            "Clear Parent PIN?",
            isPresented: Binding(
                get: { parentPINClearTarget != nil },
                set: { if !$0 { parentPINClearTarget = nil } }
            ),
            presenting: parentPINClearTarget
        ) { target in
            Button("Clear PIN", role: .destructive) {
                Task { await clearParentPIN(target) }
            }
            Button("Cancel", role: .cancel) { parentPINClearTarget = nil }
        } message: { target in
            Text("\(target.child.name) will need a new PIN the next time Parent Controls is opened on this device.")
        }
        .alert(
            "Couldn’t Clear PIN",
            isPresented: Binding(
                get: { parentPINClearError != nil },
                set: { if !$0 { parentPINClearError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { parentPINClearError = nil }
        } message: {
            Text(parentPINClearError ?? "Try again.")
        }
    }

    private func clearParentPIN(_ target: DeviceRemovalTarget) async {
        parentPINClearTarget = nil
        guard !clearingParentPINDeviceIDs.contains(target.device.device_id) else { return }
        clearingParentPINDeviceIDs.insert(target.device.device_id)
        defer { clearingParentPINDeviceIDs.remove(target.device.device_id) }
        do {
            try await apiClient.clearChildDeviceParentPIN(
                childID: target.child.id,
                deviceID: target.device.device_id
            )
            revealedParentPINDeviceIDs.remove(target.device.device_id)
            await familyStore.refresh()
            children = familyStore.childProfiles
        } catch {
            parentPINClearError = "Evlin could not clear this PIN. Check your connection and try again."
        }
    }

    private func removeDevice(_ target: DeviceRemovalTarget) async {
        guard UUID(uuidString: target.child.id) != nil,
              UUID(uuidString: target.device.device_id) != nil else {
            devicePendingRemoval = nil
            deviceRemovalError = "This device is missing a valid identifier. Refresh and try again."
            return
        }
        removingDeviceID = target.device.device_id
        defer { removingDeviceID = nil }
        do {
            try await apiClient.removeChildDevice(
                childID: target.child.id,
                deviceID: target.device.device_id
            )
            devicePendingRemoval = nil
            removingDeviceID = nil
            selectedDeviceDetailID = ParentSettingsPresentation.deviceDetailSelectionAfterRemoval(
                selectedDeviceID: selectedDeviceDetailID,
                removedDeviceID: target.device.device_id
            )

            // The deletion has committed. Refreshing all home aggregates is
            // best-effort and must not keep this destructive action spinning.
            Task {
                await familyStore.refresh()
                children = familyStore.childProfiles
            }
        } catch {
            devicePendingRemoval = nil
            deviceRemovalError = "Evlin could not remove this device. Check your connection and try again."
        }
    }

    private var appVersionDisplay: String {
        ParentSettingsPresentation.versionDisplay(
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
    }

    private var childrenDevicesSummary: String {
        ParentSettingsPresentation.childrenDevicesSummary(
            childCount: children.count,
            deviceCount: familyStore.children.reduce(0) { $0 + $1.devices.count }
        )
    }

    private var coParents: [ParentMemberDTO] {
        familyStore.parents.filter { !$0.is_owner }
    }

    private var coParentSummary: String {
        guard !coParents.isEmpty else { return "Invite another parent or caregiver" }
        return "Manage family-level access"
    }

    private var coParentValue: String {
        ParentSettingsPresentation.coParentValue(coParentCount: coParents.count)
    }

    private var notificationActionTitle: String {
        "Notification Settings"
    }

    private var notificationRootSubtitle: String {
        "\(notificationEffectiveStatusCopy) · kid requests, completions, alerts"
    }

    private var notificationPermissionBinding: Binding<Bool> {
        Binding(
            get: { notificationsEffectivelyEnabled },
            set: { wantsEnabled in
                Task {
                    await setNotificationPermissionIntent(enabled: wantsEnabled)
                }
            }
        )
    }

    private var notificationsEffectivelyEnabled: Bool {
        notifyPushEnabled && notificationAuthorizationStatus.isParentSettingsEnabled
    }

    private var notificationEffectiveStatusCopy: String {
        guard notifyPushEnabled else { return "Off" }
        return ParentSettingsPresentation.notificationStatusCopy(notificationAuthorizationStatus)
    }

    private var familyDisplayName: String {
        familyStore.family?.display_name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Family"
    }

    private var parentDisplayName: String {
        parentName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? familyStore.selfParent?.display_name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Parent"
    }

    private var parentInitials: String {
        initials(from: parentDisplayName)
    }

    private var parentEmailDisplay: String {
        "Email not exposed yet"
    }

    private var parentAccentColor: Color {
        color(fromHexString: selectedParentAccentHex) ?? .evPrimary
    }

    private enum SettingsPillTone {
        case success
        case neutral
        case warning
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        systemImage: String,
        value: String? = nil,
        pill: String? = nil,
        pillTone: SettingsPillTone = .neutral,
        accent: Color = .evPrimary,
        danger: Bool = false,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            settingsIconChip(systemImage, accent: accent, disabled: disabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(disabled ? Color.evOutline : (danger ? Color.evError : Color.evOnSurface))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.custom("Inter", size: 13).weight(.medium))
                    .foregroundStyle(disabled ? Color.evOutline : Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            if let pill, !pill.isEmpty {
                settingsPill(pill, tone: pillTone)
            }
        }
        .padding(.vertical, 4)
        .opacity(disabled ? 0.72 : 1)
    }

    private func settingsToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        accent: Color = .evPrimary
    ) -> some View {
        HStack(spacing: 12) {
            settingsIconChip(systemImage, accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Text(subtitle)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 4)
    }

    private func settingsNavigableToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        accent: Color = .evPrimary,
        navigate: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: navigate) {
                HStack(spacing: 12) {
                    settingsIconChip(systemImage, accent: accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.custom("Inter", size: 15).weight(.semibold))
                            .foregroundStyle(Color.evOnSurface)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.custom("Inter", size: 12))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.evSecondary)
                .fixedSize()

            Button(action: navigate) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
                    .frame(width: 18, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func settingsIconChip(_ systemImage: String, accent: Color, disabled: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(disabled ? Color.evOutline : accent)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((disabled ? Color.evSurfaceContainerHigh : accent.opacity(0.12)))
            )
    }

    private func settingsChildRow(_ child: ChildProfile) -> some View {
        HStack(spacing: 12) {
            childAvatarView(child, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(child.name)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Text(childDeviceSummary(for: child))
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Text(childDeviceValue(for: child))
                .font(.custom("Inter", size: 13).weight(.medium))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func childAvatarView(_ child: ChildProfile, size: CGFloat) -> some View {
        let url = childAvatarURL(for: child)
        return Group {
            if let url {
                EvlinAvatarView(url: url, name: child.name, size: size)
            } else {
                Text(child.initial)
                    .font(.custom("Manrope", size: size * 0.36).weight(.bold))
                    .foregroundStyle(Color.evOnPrimary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(childAccentColor(for: child)))
            }
        }
    }

    private func settingsPill(_ text: String, tone: SettingsPillTone) -> some View {
        let colors = pillColors(tone)
        return Text(text)
            .font(.custom("Inter", size: 12).weight(.semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(colors.background))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func pillColors(_ tone: SettingsPillTone) -> (foreground: Color, background: Color) {
        switch tone {
        case .success:
            return (.evSecondary, .evSecondaryContainer.opacity(0.65))
        case .warning:
            return (.evPrimary, .evTertiaryContainer.opacity(0.65))
        case .neutral:
            return (.evOutline, .evSurfaceContainerHigh)
        }
    }

    private func settingsProfileCard(
        title: String,
        subtitle: String,
        initials: String,
        avatarURL: String? = nil,
        accent: Color = .evPrimary
    ) -> some View {
        HStack(spacing: 12) {
            if let avatarURL {
                EvlinAvatarView(url: avatarURL, name: initials, size: 46)
            } else {
                Text(initials)
                    .font(.custom("Manrope", size: 16).weight(.bold))
                    .foregroundStyle(Color.evOnPrimary)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(accent))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom("Manrope", size: 16).weight(.bold))
                    .foregroundStyle(Color.evOnSurface)
                Text(subtitle)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.evOutline)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.7), lineWidth: 1)
        )
    }

    private var parentProfileHero: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                OnboardingV2PhotoAvatarPicker(
                    name: parentDisplayName,
                    pickedImage: $parentPickedAvatar,
                    size: 88,
                    accent: parentAccentColor,
                    existingImageURL: parentAvatarURL,
                    badgeSystemImage: "camera.fill"
                )
                .disabled(isUploadingParentAvatar)

                VStack(spacing: 3) {
                    Text(parentDisplayName)
                        .font(.custom("Manrope", size: 18).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                    Text(parentEmailDisplay)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            Divider()
                .background(Color.evOutlineVariant.opacity(0.7))
                .padding(.top, 14)
                .padding(.bottom, 14)

            accentColorPicker

            if isUploadingParentAvatar {
                ProgressView("Uploading photo...")
                    .font(.custom("Inter", size: 12))
                    .padding(.top, 12)
            }

            if let parentAvatarError {
                Text(parentAvatarError)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            if let parentAccentError {
                Text(parentAccentError)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.7), lineWidth: 1)
        )
        .onChange(of: parentPickedAvatar) { _, newValue in
            guard let newValue else { return }
            Task { await uploadParentAvatar(newValue) }
        }
    }

    private func childProfileHero(_ child: ChildProfile) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                OnboardingV2PhotoAvatarPicker(
                    name: child.name,
                    pickedImage: childPickedAvatarBinding(for: child),
                    size: 88,
                    accent: childAccentColor(for: child),
                    existingImageURL: childAvatarURL(for: child),
                    badgeSystemImage: "camera.fill"
                )
                .disabled(uploadingChildAvatarIDs.contains(child.id))

                VStack(spacing: 3) {
                    Text(child.name)
                        .font(.custom("Manrope", size: 18).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                    Text("Age \(child.age) · \(childDeviceValue(for: child))")
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            Divider()
                .background(Color.evOutlineVariant.opacity(0.7))
                .padding(.top, 14)
                .padding(.bottom, 14)

            profileAccentColorPicker(
                options: ParentSettingsPresentation.childProfileHeroAccentHexOptions,
                selectedHex: selectedChildAccentHex(for: child),
                isSaving: savingChildAccentIDs.contains(child.id),
                accessibilityPrefix: "Choose child accent color"
            ) { hex in
                Task { await selectChildAccent(hex, for: child) }
            }

            if uploadingChildAvatarIDs.contains(child.id) {
                ProgressView("Uploading photo...")
                    .font(.custom("Inter", size: 12))
                    .padding(.top, 12)
            }

            if let error = childAvatarErrorByID[child.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            if let error = childAccentErrorByID[child.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.evError)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.7), lineWidth: 1)
        )
    }

    private var accentColorPicker: some View {
        profileAccentColorPicker(
            options: ParentSettingsPresentation.parentProfileHeroAccentHexOptions,
            selectedHex: selectedParentAccentHex,
            isSaving: isSavingParentAccent,
            accessibilityPrefix: "Choose accent color"
        ) { hex in
            Task { await selectParentAccent(hex) }
        }
    }

    private func profileAccentColorPicker(
        options: [String],
        selectedHex: String,
        isSaving: Bool,
        accessibilityPrefix: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(spacing: 9) {
            Text("Accent Color")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOutline)
            HStack(spacing: 7) {
                ForEach(options, id: \.self) { hex in
                    Button {
                        onSelect(hex)
                    } label: {
                        accentSwatch(hex, selectedHex: selectedHex)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .accessibilityLabel("\(accessibilityPrefix) \(hex)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func accentSwatch(_ hex: String, selectedHex: String) -> some View {
        let selected = hex.caseInsensitiveCompare(selectedHex) == .orderedSame
        return ZStack {
            Circle()
                .fill(color(fromHexString: hex) ?? .evPrimary)
                .frame(width: 24, height: 24)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(
            Circle()
                .stroke(selected ? Color.evOnSurface : Color.evOutlineVariant, lineWidth: selected ? 2 : 1)
        )
    }

    private func settingsHeroNote(title: String, message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.custom("Manrope", size: 15).weight(.bold))
                    .foregroundStyle(Color.evOnSurface)
                Text(message)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.vertical, 4)
        }
    }

    private func childDeviceSummary(for child: ChildProfile) -> String {
        let deviceCount = backendChild(for: child)?.devices.count ?? 0
        if deviceCount == 0 {
            return "Age \(child.age) · no child devices"
        }
        let labels = (backendChild(for: child)?.devices ?? [])
            .prefix(2)
            .map(deviceDisplayName)
            .joined(separator: " · ")
        return "Age \(child.age) · \(labels.isEmpty ? childDeviceValue(for: child) : labels)"
    }

    private func childDeviceValue(for child: ChildProfile) -> String {
        let deviceCount = backendChild(for: child)?.devices.count ?? 0
        return "\(deviceCount) \(deviceCount == 1 ? "device" : "devices")"
    }

    private func currentChild(for child: ChildProfile) -> ChildProfile {
        children.first(where: { $0.id == child.id }) ?? familyStore.childProfiles.first(where: { $0.id == child.id }) ?? child
    }

    private func childAvatarURL(for child: ChildProfile) -> String? {
        ParentSettingsPresentation.childSettingsAvatarURL(
            childAvatarURLByID[child.id] ?? currentChild(for: child).avatarURL
        )
    }

    private func selectedChildAccentHex(for child: ChildProfile) -> String {
        if let selected = selectedChildAccentHexByID[child.id] {
            return selected
        }
        if let serverHex = backendChild(for: child)?.avatar.color,
           let normalized = normalizedHex(serverHex),
           ParentSettingsPresentation.childProfileHeroAccentHexOptions.contains(normalized) {
            return normalized
        }
        return ParentSettingsPresentation.childProfileHeroAccentHexOptions[0]
    }

    private func childAccentColor(for child: ChildProfile) -> Color {
        color(fromHexString: selectedChildAccentHex(for: child)) ?? currentChild(for: child).accentColor
    }

    private func childPickedAvatarBinding(for child: ChildProfile) -> Binding<UIImage?> {
        Binding(
            get: { childPickedAvatarByID[child.id] },
            set: { newValue in
                childPickedAvatarByID[child.id] = newValue
                guard let newValue else { return }
                Task { await uploadChildAvatar(newValue, for: child) }
            }
        )
    }

    private func childDeviceIcon(for child: ChildProfile) -> String {
        let deviceCount = backendChild(for: child)?.devices.count ?? 0
        return deviceCount > 1 ? "ipad.and.iphone" : "iphone"
    }

    private func backendChild(for child: ChildProfile) -> ChildDTO? {
        familyStore.child(byId: child.id)
    }

    private func deviceDisplayName(_ device: EnrolledDeviceDTO) -> String {
        device.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? device.display?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? device.device_model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Child Device"
    }

    private func deviceStatusLine(_ device: EnrolledDeviceDTO) -> String {
        let state = device.online ? "Online" : "Offline"
        guard let lastSeen = device.last_seen_at?.trimmingCharacters(in: .whitespacesAndNewlines), !lastSeen.isEmpty else {
            return "\(state) · last heartbeat unavailable"
        }
        return "\(state) · last seen \(lastSeen)"
    }

    private func deviceKind(_ device: EnrolledDeviceDTO) -> String {
        let platform = device.platform?.uppercased()
        return platform?.nilIfEmpty ?? (device.mode == "child" ? "Kid" : "Parent")
    }

    private func deviceIcon(_ device: EnrolledDeviceDTO) -> String {
        let display = [device.display, device.label, device.device_model]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if display.contains("ipad") { return "ipad" }
        return "iphone"
    }

    private func initials(from name: String) -> String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .compactMap { $0.first }
            .prefix(2)
        let value = parts.map(String.init).joined().uppercased()
        return value.isEmpty ? "P" : value
    }

    @ViewBuilder
    private var debugSettingsMenu: some View {
        Form {
            Section("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Backend Preset")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.evOutline)
                    Picker("Backend", selection: $serverURL) {
                        Text("Local").tag(APIClient.localDevURL)
                        Text("Production").tag(APIClient.defaultURL)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: serverURL) { oldValue, newValue in
                        let isPreset = newValue == APIClient.localDevURL
                            || newValue == APIClient.defaultURL
                        guard isPreset else { return }
                        apiClient.saveServerURL(newValue)

                        guard !oldValue.isEmpty, oldValue != newValue else { return }
                        UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                        UserDefaults.standard.removeObject(forKey: "evlin.parentDeviceID")
                        UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                        DeviceIdentity.shared.clear()
                        UserDefaults.standard.set(false, forKey: "onboardingComplete")
                        UserDefaults.standard.set("", forKey: "appMode")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.evOutline)
                    TextField("http://192.168.1.x:8000/api/v1", text: $serverURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Child Name")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.evOutline)
                    TextField("Child's name", text: $childName)
                }

                if !familyID.isEmpty {
                    idRow(title: "Family ID", value: familyID)
                }
                if !parentDeviceID.isEmpty {
                    idRow(title: "Parent Device ID", value: parentDeviceID)
                }
                if !childDeviceID.isEmpty {
                    idRow(title: "Child Device ID", value: childDeviceID)
                }
            }

            Section("Screen Time Debug") {
                let appCount = screenTimeManager.selectedApps.applicationTokens.count
                let catCount = screenTimeManager.selectedApps.categoryTokens.count
                let webCount = screenTimeManager.selectedApps.webDomainTokens.count

                Button {
                    isPickerPresented = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Managed Apps & Categories")
                                .foregroundStyle(Color.evOnSurface)
                            if appCount > 0 || catCount > 0 || webCount > 0 {
                                Text("\(appCount) apps, \(catCount) categories, \(webCount) websites")
                                    .font(.caption)
                                    .foregroundStyle(Color.evOutline)
                            } else {
                                Text("Nothing selected yet")
                                    .font(.caption)
                                    .foregroundStyle(Color.evOutline)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.evOutline)
                    }
                }

                ManagedActivitySelectionDiagnostics(selection: screenTimeManager.selectedApps)

                if appCount > 0 || catCount > 0 || webCount > 0 {
                    Button {
                        // C-3/D-2: route through the single stable Home
                        // settings record — ActiveLockStore is the only
                        // ManagedSettings shield writer.
                        let childID = UUID(uuidString: childDeviceID) ?? UUID()
                        let selection = screenTimeManager.selectedApps
                        Task {
                            let locked = await HomeSettingsLockRouting.lock(
                                selection: selection,
                                childID: childID
                            )
                            if locked {
                                await MainActor.run {
                                    NotificationCenter.default.post(
                                        name: .evlinLockStateChanged, object: true)
                                }
                            }
                        }
                    } label: {
                        Label("Lock Selected Apps", systemImage: "lock.fill")
                            .foregroundStyle(Color.evError)
                    }
                }

                Button {
                    // C-3/D-2: removes ONLY the Home settings manual record.
                    // Automatic locks (earned/task/reflection/limit) and
                    // blocks are untouched — hence "Selected", not "All".
                    Task {
                        _ = await HomeSettingsLockRouting.unlock()
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .evlinLockStateChanged, object: false)
                        }
                    }
                } label: {
                    Label("Unlock Selected Apps", systemImage: "lock.open.fill")
                        .foregroundStyle(Color.evSecondary)
                }

                Button(role: .destructive) {
                    Task { await nuclearReset() }
                } label: {
                    Label("Nuclear Reset (lock state)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.evError)
                }
            }

            Section("Camera & Photos") {
                HStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(Color.evOutline)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Camera")
                            .foregroundStyle(Color.evOnSurface)
                        Text(cameraStatusText)
                            .font(.caption)
                            .foregroundStyle(Color.evOutline)
                    }
                    Spacer()
                }
                Group {
                    if cameraIsAuthorized {
                        Text("Ready for task evidence and profile photos.")
                            .font(.caption)
                            .foregroundStyle(Color.evSecondary)
                    } else {
                        Button(cameraPermissionActionTitle) {
                            handleCameraPermissionTap()
                        }
                    }
                }
                .id(cameraPermissionFreshness)

                Text("Camera is used when your child submits task photos or evidence.")
                    .font(.caption)
                    .foregroundStyle(Color.evOutline)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Evlin Settings", systemImage: "slider.horizontal.3")
                }
            }

            Section("Mode") {
                HStack {
                    Text("Current Mode")
                    Spacer()
                    Text(appMode == "parent" ? "Parent" : "Child")
                        .foregroundStyle(Color.evPrimary)
                }

                Button(role: .destructive) {
                    appMode = "setup"
                    onClose()
                } label: {
                    Label("Switch Device Mode", systemImage: "arrow.triangle.2.circlepath")
                }

                if appMode == "parent" {
                    Button {
                        EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
                        appMode = "child"
                        onClose()
                    } label: {
                        Label("Switch to Child Mode", systemImage: "figure.child")
                    }
                } else if appMode == "child" {
                    Button {
                        appMode = "parent"
                        onClose()
                    } label: {
                        Label("Switch to Parent Mode", systemImage: "person.fill")
                    }
                }

                Button(role: .destructive) {
                    // C-3/D-2: full reset clears ALL shield + block records
                    // through ActiveLockStore (its recompute nils the
                    // ManagedSettings fields) instead of writing them here.
                    Task {
                        _ = await ActiveLockStore.shared.unshieldAll()
                        _ = await ActiveLockStore.shared.unblockAll()
                        await MainActor.run {
                            screenTimeManager.syncDeletionProtectionToManagedSettings()
                            NotificationCenter.default.post(
                                name: .evlinLockStateChanged, object: false)
                        }
                    }
                    UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                    UserDefaults.standard.removeObject(forKey: "appMode")
                    UserDefaults.standard.removeObject(forKey: "childId")
                    UserDefaults.standard.removeObject(forKey: "childName")
                    UserDefaults.standard.removeObject(forKey: "targetChildId")
                    UserDefaults.standard.removeObject(forKey: "evlin.familyID")
                    UserDefaults.standard.removeObject(forKey: "evlin.parentDeviceID")
                    UserDefaults.standard.removeObject(forKey: "evlin.childDeviceID")
                    DeviceIdentity.shared.clear()
                    UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
                    UserDefaults.standard.removeObject(forKey: "serverURL")
                    EvlinDemoShortcuts.clearFlag()
                    NotificationCenter.default.post(name: .evlinClearChat, object: nil)
                    appMode = ""
                    onClose()
                } label: {
                    Label("Reset Everything (Re-run Onboarding)", systemImage: "arrow.counterclockwise")
                }
            }

            Section("Protection Mode") {
                if let famID = UUID(uuidString: familyID) {
                    Picker("Protection Mode", selection: $protectionMode) {
                        Text("Standard (.individual)").tag("std")
                        Text("Maximum (.child)").tag("max")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: protectionMode) { old, new in
                        Task {
                            do {
                                try await apiClient.setProtectionMode(familyID: famID, mode: new)
                                await MainActor.run {
                                    protectionModeStatus = "Set to \(new.uppercased())"
                                    UserDefaults.standard.set(new, forKey: "evlin.protectionMode")
                                }
                            } catch {
                                await MainActor.run {
                                    protectionMode = old
                                    UserDefaults.standard.set(old, forKey: "evlin.protectionMode")
                                    protectionModeStatus = "Failed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                    if !protectionModeStatus.isEmpty {
                        Text(protectionModeStatus)
                            .font(.caption)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                } else {
                    Text("Pair a device first — we need a family id to sync protection mode.")
                        .font(.caption)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            diagnosticsSections

            Section("Spike Tests") {
                NavigationLink {
                    SpikeView()
                } label: {
                    Label("Diagnostics & Spike Tests", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink {
                    LabelTokenInspectorView()
                } label: {
                    Label("Label(token) snapshot test", systemImage: "rectangle.and.text.magnifyingglass")
                }
                NavigationLink {
                    ShieldHarvestProbeView()
                } label: {
                    Label("ShieldConfig harvest (E1)", systemImage: "lock.doc")
                }
                NavigationLink {
                    DeviceActivityReportMetadataProbeView()
                } label: {
                    Label("DeviceActivityReport metadata test", systemImage: "chart.bar.doc.horizontal")
                }
                #if DEBUG
                NavigationLink {
                    DARNumberExportProbeView()
                } label: {
                    Label("DAR number export (total screen time)", systemImage: "number.circle")
                }
                NavigationLink {
                    WholeDeviceThresholdProbeView()
                } label: {
                    Label("Whole-device threshold test", systemImage: "bolt.badge.clock")
                }
                NavigationLink {
                    EarnedTimeMeasurementCaptureView()
                } label: {
                    Label("Earned time — measurement capture (B3)", systemImage: "timer.circle")
                }
                #endif
                NavigationLink {
                    LockActivityReviewScreen()
                } label: {
                    Label("Lock activity review", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    TokenScreenshotImportView()
                } label: {
                    Label("Auto-tag via screenshots", systemImage: "camera.viewfinder")
                }
                NavigationLink {
                    TokenPickerProbeView()
                } label: {
                    Label("Lazy-tag picker test", systemImage: "tag")
                }
                NavigationLink {
                    AliasLibraryInspectorView()
                } label: {
                    Label("Alias library (after hydrate)", systemImage: "books.vertical")
                }
                NavigationLink {
                    AliasE2ETestView()
                } label: {
                    Label("Alias E2E test (start here)", systemImage: "checkmark.seal")
                }
                NavigationLink {
                    QrSpikeDebugView()
                } label: {
                    Label("QR-over-pixel DAR spike", systemImage: "qrcode.viewfinder")
                }
                NavigationLink {
                    ChildAppCatalogDebugView()
                } label: {
                    Label("Child app catalog cross-device test", systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
                NavigationLink {
                    ChildPickerSpikeView()
                } label: {
                    Label(".child parent picker spike", systemImage: "person.2.badge.gearshape")
                }
            }
        }
        .navigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(
            isPresented: $isPickerPresented,
            selection: $screenTimeManager.selectedApps
        )
        .onChange(of: isPickerPresented) { _, open in
            // `FamilyActivitySelection` equality can ignore picker-only metadata deltas; always
            // persist when the sheet closes so `LocalAliasStore` + label snapshots refresh.
            if !open {
                screenTimeManager.saveSelection()
            }
        }
        .onChange(of: screenTimeManager.selectedApps) { _, _ in
            screenTimeManager.saveSelection()
        }
    }

    @ViewBuilder
    private var diagnosticsSections: some View {
#if DEBUG
        Section {
            NavigationLink {
                MeteringDaemonDiagnosticsView()
            } label: {
                Label("Metering Daemon", systemImage: "gauge.with.dots.needle.67percent")
            }
        } header: {
            Text("Metering")
        } footer: {
            Text("Read-only daemon configuration evidence for Total Pool, Device Limit, and Per-App Limit.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
#endif

        Section {
            NavigationLink {
                CommandDeliveryDiagnosticsView()
            } label: {
                Label("Command Delivery", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Command Delivery")
        } footer: {
            Text("Use this when parent commands do not land on the kid device. On the kid phone, prefer opening this from Kid mode so switching modes does not poll and contaminate the result.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Section {
            let lastResult = UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.lastScheduleResult")
                ?? "(no schedule attempted yet — set a timed lock first)"
            Text(lastResult)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lastResult.contains("FAILED") ? Color.red : Color.evOnSurface)
                .textSelection(.enabled)
        } header: {
            Text("Last Auto-Unshield Schedule")
        }

        Section {
            let failure = UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.reflectionLockScheduleFailure") ?? "none"
            Text(failure)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(failure == "none" ? Color.evOnSurface : Color.red)
                .textSelection(.enabled)
        } header: {
            Text("Reflection lock schedule")
        }

        Section {
            let lastFired = UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.lastIntervalDidEnd")
                ?? "(extension never fired since launch)"
            Text(lastFired)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lastFired.contains("shieldRemoved=false") ? Color.orange : Color.evOnSurface)
                .textSelection(.enabled)
        } header: {
            Text("Last Extension Fire")
        }

        Section {
            let lastRecompute = UserDefaults(suiteName: "group.com.evlin.ios")?
                .string(forKey: "evlin.lastRecompute")
                ?? "(no recompute since install)"
            Text(lastRecompute)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.evOnSurface)
                .textSelection(.enabled)
        } header: {
            Text("Last Recompute")
        }
    }

    private var cameraIsAuthorized: Bool {
        _ = cameraPermissionFreshness
        if case .authorized = AVCaptureDevice.authorizationStatus(for: .video) { return true }
        return false
    }

    private var cameraStatusText: String {
        _ = cameraPermissionFreshness
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Blocked — use Evlin Settings below"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var cameraPermissionActionTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return "Allow Camera Access"
        case .authorized: return ""
        default: return "Fix Camera in Settings…"
        }
    }

    private func handleCameraPermissionTap() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    cameraPermissionFreshness += 1
                }
            }
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Task { await UIApplication.shared.open(url) }
            }
        }
    }

    private func refreshNotificationAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }

    private func currentNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    @MainActor
    private func reconcileNotificationStateAfterSystemSettings() async {
        let status = await currentNotificationAuthorizationStatus()
        notificationAuthorizationStatus = status
        guard pendingNotificationSystemSettingsIntent != nil else { return }
        pendingNotificationSystemSettingsIntent = nil

        let systemEnabled = status.isParentSettingsEnabled
        if await setParentPushPreference(enabled: systemEnabled),
           systemEnabled {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    @MainActor
    private func setNotificationPermissionIntent(enabled: Bool) async {
        let currentStatus = await currentNotificationAuthorizationStatus()
        notificationAuthorizationStatus = currentStatus
        switch ParentSettingsPresentation.notificationPermissionAction(
            status: currentStatus,
            wantsEnabled: enabled
        ) {
        case .requestAuthorization:
            let granted = await requestNotificationAuthorization()
            if granted {
                _ = await setParentPushPreference(enabled: true)
            } else {
                notifyPushEnabled = false
            }
        case .openSystemSettings:
            pendingNotificationSystemSettingsIntent = enabled
            await openIOSNotificationSettings()
        case .setLocalPreference:
            if await setParentPushPreference(enabled: enabled),
               enabled,
               notificationAuthorizationStatus.isParentSettingsEnabled {
                UIApplication.shared.registerForRemoteNotifications()
            }
            refreshNotificationAuthorizationStatus()
        case .refreshStatus:
            refreshNotificationAuthorizationStatus()
        }
    }

    @MainActor
    private func handleNotificationPermissionTap() async {
        await openIOSNotificationSettings()
        refreshNotificationAuthorizationStatus()
    }

    @MainActor
    private func openIOSNotificationSettings() async {
        if #available(iOS 16.0, *),
           let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            await UIApplication.shared.open(url)
            return
        }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }

    @MainActor
    private func refreshParentNotificationPreferences() async {
        guard let prefs = try? await apiClient.fetchNotificationPreferences() else { return }
        notifyPushEnabled = !prefs.muted_types.contains(ParentSettingsPresentation.parentPushMasterMuteType)
    }

    @MainActor
    private func setParentPushPreference(enabled: Bool) async -> Bool {
        let previous = notifyPushEnabled
        notifyPushEnabled = enabled

        do {
            let prefs = try await apiClient.fetchNotificationPreferences()
            var mutedTypes = Set(prefs.muted_types)
            if enabled {
                mutedTypes.remove(ParentSettingsPresentation.parentPushMasterMuteType)
            } else {
                mutedTypes.insert(ParentSettingsPresentation.parentPushMasterMuteType)
            }
            let updated = try await apiClient.updateNotificationPreferences(
                UpdateNotificationPreferencesBody(
                    quiet_hours_start: nil,
                    quiet_hours_end: nil,
                    digest_enabled: nil,
                    muted_types: Array(mutedTypes).sorted()
                )
            )
            notifyPushEnabled = !updated.muted_types.contains(ParentSettingsPresentation.parentPushMasterMuteType)
            AppDelegate.uploadCachedAPNsTokenIfPossible(using: apiClient)
            return true
        } catch {
            notifyPushEnabled = previous
            return false
        }
    }

    @MainActor
    @discardableResult
    private func requestNotificationAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false

        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }

        refreshNotificationAuthorizationStatus()
        return granted
    }

    private func seedParentProfilePresentation() {
        parentAvatarURL = familyStore.selfParent?.avatar.signed_url

        if let serverHex = familyStore.selfParent?.avatar.color,
           let normalized = normalizedHex(serverHex),
           ParentSettingsPresentation.parentAccentHexOptions.contains(normalized) {
            selectedParentAccentHex = normalized
        }
    }

    @MainActor
    private func selectParentAccent(_ hex: String) async {
        guard let normalized = normalizedHex(hex) else { return }
        guard normalized.caseInsensitiveCompare(selectedParentAccentHex) != .orderedSame else { return }
        guard !isSavingParentAccent else { return }

        let previous = selectedParentAccentHex
        selectedParentAccentHex = normalized
        isSavingParentAccent = true
        defer { isSavingParentAccent = false }

        do {
            _ = try await apiClient.updateParentProfile(
                UpdateParentProfileBody(
                    display_name: nil,
                    avatar_kind: nil,
                    avatar_value: nil,
                    avatar_color: normalized
                )
            )
            await familyStore.refresh()
            seedParentProfilePresentation()
            parentAccentError = nil
        } catch {
            selectedParentAccentHex = previous
            parentAccentError = "Couldn't save accent color. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func uploadParentAvatar(_ image: UIImage) async {
        guard !isUploadingParentAvatar else { return }
        guard let data = evlinAvatarJPEG(image) else {
            parentAvatarError = "Couldn't prepare that photo."
            return
        }

        isUploadingParentAvatar = true
        defer { isUploadingParentAvatar = false }

        do {
            let response: APIClient.AvatarUploadResponse = try await apiClient.uploadParentAvatar(jpegData: data)
            parentAvatarURL = response.signed_url
            await familyStore.refresh()
            parentAvatarURL = familyStore.selfParent?.avatar.signed_url ?? response.signed_url
            parentAvatarError = nil
        } catch {
            parentAvatarError = "Couldn't upload photo. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func selectChildAccent(_ hex: String, for child: ChildProfile) async {
        guard let normalized = normalizedHex(hex) else { return }
        guard normalized.caseInsensitiveCompare(selectedChildAccentHex(for: child)) != .orderedSame else { return }
        guard !savingChildAccentIDs.contains(child.id) else { return }

        let previous = selectedChildAccentHexByID[child.id]
        selectedChildAccentHexByID[child.id] = normalized
        savingChildAccentIDs.insert(child.id)
        defer { savingChildAccentIDs.remove(child.id) }

        do {
            _ = try await apiClient.updateChild(
                id: child.id,
                UpdateChildBody(
                    display_name: nil,
                    birth_year: nil,
                    gender: nil,
                    avatar_kind: nil,
                    avatar_value: nil,
                    avatar_color: normalized
                )
            )
            await familyStore.refresh()
            children = familyStore.childProfiles
            if let refreshedHex = backendChild(for: child)?.avatar.color,
               let normalizedRefreshed = normalizedHex(refreshedHex) {
                selectedChildAccentHexByID[child.id] = normalizedRefreshed
            }
            childAccentErrorByID[child.id] = nil
        } catch {
            if let previous {
                selectedChildAccentHexByID[child.id] = previous
            } else {
                selectedChildAccentHexByID.removeValue(forKey: child.id)
            }
            childAccentErrorByID[child.id] = "Couldn't save accent color. \(error.localizedDescription)"
        }
    }

    @MainActor
    private func uploadChildAvatar(_ image: UIImage, for child: ChildProfile) async {
        guard !uploadingChildAvatarIDs.contains(child.id) else { return }
        guard let data = evlinAvatarJPEG(image) else {
            childAvatarErrorByID[child.id] = "Couldn't prepare that photo."
            return
        }

        uploadingChildAvatarIDs.insert(child.id)
        defer { uploadingChildAvatarIDs.remove(child.id) }

        do {
            let signedURL = try await apiClient.uploadChildAvatar(childId: child.id, jpegData: data)
            if let signedURL {
                childAvatarURLByID[child.id] = signedURL
            }
            await familyStore.refresh()
            children = familyStore.childProfiles
            if let refreshed = familyStore.childProfiles.first(where: { $0.id == child.id })?.avatarURL ?? signedURL {
                childAvatarURLByID[child.id] = refreshed
            }
            childAvatarErrorByID[child.id] = nil
        } catch {
            childAvatarErrorByID[child.id] = "Couldn't upload photo. \(error.localizedDescription)"
        }
    }

    private func requestSessionExit() {
        sessionExitCoordinator.requestExit(dismiss: onClose)
    }

    private func tearDownLocalSession() {
        // C2 fix: route through AuthService.signOutLocally() so the P0-1
        // chat-clear path (evlinClearChat → clearAllLocal + setAccount(nil))
        // always runs on sign-out. AuthService clears the Keychain, posts
        // evlinClearChat, and removes evlin.accountID. We handle the
        // remaining app-state resets (onboarding / family prefs) here.
        AuthService(api: apiClient).signOutLocally()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "onboardingComplete")
        defaults.set("", forKey: "appMode")
        defaults.removeObject(forKey: "evlin.familyID")
        defaults.removeObject(forKey: "evlin.parentDeviceID")
        defaults.removeObject(forKey: "evlin.childDeviceID")
        DeviceIdentity.shared.clear()
        defaults.removeObject(forKey: "parentName")
        defaults.removeObject(forKey: "childName")
        defaults.removeObject(forKey: "targetChildId")
        // evlinSessionSignedOut drives HomeView back to signed-out state.
        NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
    }

    private func color(fromHexString hex: String) -> Color? {
        guard let normalized = normalizedHex(hex) else { return nil }
        let raw = String(normalized.dropFirst())
        guard let value = UInt32(raw, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    private func normalizedHex(_ hex: String) -> String? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return nil }
        return "#\(s)"
    }

    @ViewBuilder
    private func idRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom("Inter", size: 11).weight(.bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.evOutline)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .textSelection(.enabled)
        }
    }

    private var referenceYear: Int { Calendar.current.component(.year, from: Date()) }

    /// HP-14: push an edited parent name to the backend
    /// (`PUT /me/profile`) and refresh the family aggregate so HomeView's
    /// header (which prefers `selfParent.display_name`) picks it up.
    /// Returns true when there was nothing to save or the save succeeded;
    /// false on failure (an inline error is shown and the sheet should
    /// stay open).
    @MainActor
    private func saveParentNameIfChanged() async -> Bool {
        let trimmed = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = parentNameAtOpen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != baseline else { return true }
        guard !isSavingParentName else { return false }
        isSavingParentName = true
        defer { isSavingParentName = false }
        do {
            _ = try await apiClient.updateParentProfile(
                UpdateParentProfileBody(
                    display_name: trimmed,
                    avatar_kind: nil,
                    avatar_value: nil,
                    avatar_color: nil
                )
            )
            await familyStore.refresh()
            parentNameAtOpen = trimmed   // new baseline — don't re-PUT on Done
            parentNameError = nil
            return true
        } catch {
            parentNameError = "Couldn't save parent name. \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func saveEditedChild(id: String, name: String, age: Int) async {
        isChildOpInFlight = true
        defer { isChildOpInFlight = false }
        do {
            _ = try await apiClient.updateChild(
                id: id,
                ChildCRUDMapper.updateBody(name: name, age: age, referenceYear: referenceYear))
            await familyStore.refresh()
            children = familyStore.childProfiles
            editing = nil
            childOpError = nil
        } catch {
            childOpError = ChildCRUDMapper.saveErrorMessage(for: error)
        }
    }

    @MainActor
    private func deleteChildren(_ toDelete: [ChildProfile]) async {
        isChildOpInFlight = true
        defer { isChildOpInFlight = false }
        for child in toDelete {
            do {
                try await apiClient.deleteChild(id: child.id)
            } catch {
                // 409 (linked device) or other — keep the child, show why.
                childOpError = ChildCRUDMapper.deleteErrorMessage(for: error)
                break
            }
        }
        await familyStore.refresh()
        children = familyStore.childProfiles                // truth wins; failed delete stays
    }

    /// Nuclear reset — wipes every layer that holds lock state. See the
    /// Button comment above for rationale. Idempotent: safe to call when
    /// nothing is locked. Async because ActiveLockStore is an actor.
    private func nuclearReset() async {
        // Steps 1-4 (stop every activity, drop all ManagedSettings policy, wipe
        // ActiveLockStore records, scrub App Group JSON) are shared with the
        // K-end Command Delivery nuclear reset — see `MeteringNuclearReset`.
        _ = await MeteringNuclearReset.run()

        // Re-enable deletion protection. clearAllSettings() drops
        // application.denyAppRemoval, which means the parent could accidentally
        // delete Evlin → lose enforcement. Put it back, and sync the UI flag.
        await MainActor.run {
            screenTimeManager.enableDeletionProtection()
            // Update the local UI flag so the lock indicator agrees.
            screenTimeManager.isUnlocked = true
            NotificationCenter.default.post(name: .evlinLockStateChanged, object: false)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension UNAuthorizationStatus {
    var isParentSettingsEnabled: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}

private struct ChildEditSheet: View {
    let child: ChildProfile?
    var onSave: (_ name: String, _ age: Int) -> Void

    @State private var name: String = ""
    @State private var age: Int = 8

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Stepper("Age: \(age)", value: $age, in: 1...18)
                }
            }
            .navigationTitle(child == nil ? "Add child" : "Edit \(child?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let c = child {
                    name = c.name
                    age = c.age
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), age)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

#Preview {
    HomeSettingsSheet(onClose: {})
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}

/// Share sheet for the §5.4(a) data export — lets the parent save the JSON to
/// Files, AirDrop it, or mail it to themselves.
struct DataExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
