import SwiftUI
import FamilyControls
import UIKit

@main
struct Evlin_iOSApp: App {
    /// Bridges UIKit's app-delegate callbacks into our SwiftUI lifecycle —
    /// specifically APNs registration and silent (`content-available:1`)
    /// remote-push delivery, which have no SwiftUI-native equivalent. See
    /// `AppDelegate` below.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    /// Tracks lifecycle so CommandPoller can start/stop with the scene.
    @Environment(\.scenePhase) private var scenePhase

    /// Mirrors FloatingModeToggle's storage so we can flip the poller on
    /// every parent↔child mode switch (single-device dev). On real
    /// two-device deployments the parent device never has
    /// `evlin.childDeviceID` set, so the guard inside is moot.
    @AppStorage("appMode") private var appMode: String = ""

    init() {
        // One-shot migration from legacy evlin.activeLocks store.
        // Pre-launch, so safe to drop legacy data. See plan Phase 11.
        ActiveLockMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The Evlin design system ("Informed Sentinel") is a
                // light-mode-only spec — surface containers, card
                // backgrounds, ghost borders all assume light. Without
                // this, system dark mode flips Text() to white but
                // leaves our hardcoded light backgrounds light → white
                // text on white card → invisible (e.g. Instagram label
                // on ProposalCard, app names on the lazy-tag picker).
                // Force light app-wide instead of patching each view.
                .preferredColorScheme(.light)
                .environmentObject(apiClient)
                .environmentObject(screenTimeManager)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
                .onAppear { startPollerIfPaired() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: startPollerIfPaired()
                    case .background, .inactive: CommandPoller.shared.stop()
                    @unknown default: break
                    }
                }
                .onChange(of: appMode) { _, _ in
                    // Toggling P↔K starts/stops the poller — see the
                    // doc on startPollerIfPaired for why.
                    startPollerIfPaired()
                }
                .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
                    // Demo bootstrap (or parent approve) can rewrite `evlin.childDeviceID` while
                    // already in K mode — restart polling with the fresh UUID.
                    startPollerIfPaired()
                }
        }
    }

    /// Start CommandPoller only when the user is in K mode. The poller
    /// applies queued shield/block commands to THIS device's
    /// ManagedSettings, which is correct for the kid device but wrong
    /// for the parent device — the parent should never lock itself.
    ///
    /// Two-device deployment: parent device never has
    /// `evlin.childDeviceID` set (only the kid's pairing writes it), so
    /// the guard is moot there. The single-device dev affordance
    /// (FloatingModeToggle flipping appMode) is what makes mode-gating
    /// matter: P mode = parent dashboard view, no commands applied;
    /// switch to K mode = poller starts, queued commands flush.
    ///
    /// Tradeoff: commands queued while parent is in P mode wait until
    /// the user toggles to K mode. That's the behavior we want — it
    /// mirrors the real 2-device flow ("kid device picks up when it
    /// next polls"). On scenePhase != .active we stop too so a
    /// backgrounded kid device doesn't keep polling.
    private func startPollerIfPaired() {
        guard let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let deviceID = UUID(uuidString: raw)
        else { return }
        let appMode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard appMode == "child" else {
            CommandPoller.shared.stop()
            return
        }
        CommandPoller.shared.start(deviceID: deviceID, apiClient: apiClient)
    }
}

/// UIKit app-delegate bridge for APNs.
///
/// SwiftUI's `App`/`ScenePhase` has no hook for remote-notification
/// registration or silent-push delivery, so we attach a minimal
/// `UIApplicationDelegate` via `@UIApplicationDelegateAdaptor`. Its only job
/// is the L2 silent-push path (Phase 5):
///   1. Register for remote notifications at launch.
///   2. On success, hex-encode the device token and upload it to
///      `POST /child/register-apns` for the current child device.
///   3. On a background `content-available:1` push, run a one-shot
///      `CommandPoller` poll so queued shield/block commands apply even when
///      the app isn't foregrounded.
///
/// Note: real APNs on a physical device additionally needs the Push
/// Notifications capability (the `aps-environment` entitlement) + a
/// provisioning profile. That's a device-signing step; the code and the
/// `UIBackgroundModes: remote-notification` Info.plist key compile and run on
/// the simulator without it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// UserDefaults key for the most-recent hex-encoded APNs device token.
    /// Cached unconditionally on `didRegister...` so a token that arrives
    /// before pairing isn't lost — `uploadCachedAPNsTokenIfPossible()` (and
    /// the pairing hook in ContentView) replay it once `childDeviceID` exists.
    static let apnsDeviceTokenDefaultsKey = "evlin.apnsDeviceToken"

    /// Dedicated client for token upload. Reads the same persisted `serverURL`
    /// as the app's `@StateObject` client, so it targets the same backend.
    private let apiClient = APIClient()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Ask iOS for an APNs token. The result arrives asynchronously in
        // didRegister.../didFailToRegister... below. Safe to call every
        // launch; iOS coalesces and returns the cached token quickly.
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // ALWAYS cache the token first. APNs can deliver the token before the
        // device has paired as a child (no `childDeviceID` yet); caching means
        // the pairing hook (ContentView.onChange(of: pairedChildID)) can upload
        // it the moment pairing completes — no relaunch required.
        UserDefaults.standard.set(token, forKey: Self.apnsDeviceTokenDefaultsKey)
        AppDelegate.uploadCachedAPNsTokenIfPossible(using: apiClient)
    }

    /// Upload the cached APNs token for the current child device, but only if
    /// BOTH a cached token and a paired `childDeviceID` exist. Idempotent —
    /// `registerAPNsToken` is safe to call repeatedly (POST upsert), so this is
    /// fine to invoke on every `didRegister...` and on every pairing change.
    ///
    /// The pure decision (are both present and valid?) lives in
    /// `shouldUploadAPNsToken(cachedToken:childDeviceID:)` so it's unit-testable
    /// without UIKit, mirroring how `AppControlRouter` isolates routing logic.
    static func uploadCachedAPNsTokenIfPossible(using apiClient: APIClient) {
        let cached = UserDefaults.standard.string(forKey: apnsDeviceTokenDefaultsKey)
        let childID = UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
        guard let upload = shouldUploadAPNsToken(cachedToken: cached, childDeviceID: childID) else {
            return
        }
        Task {
            do {
                try await apiClient.registerAPNsToken(deviceID: upload.deviceID, token: upload.token)
            } catch {
                print("[AppDelegate] APNs token upload failed: \(error)")
            }
        }
    }

    /// Pure decision: should the cached APNs token be uploaded, and with what
    /// args? Returns the `(deviceID, token)` to upload only when BOTH a
    /// non-empty token and a parseable `childDeviceID` UUID are present; nil
    /// otherwise (not paired yet, or no token cached). Extracted as a pure
    /// function — no UIKit, no UserDefaults — so it's unit-testable in
    /// isolation, mirroring how `AppControlRouter` isolates routing logic.
    static func shouldUploadAPNsToken(
        cachedToken: String?,
        childDeviceID: String?
    ) -> (deviceID: UUID, token: String)? {
        guard
            let token = cachedToken,
            !token.isEmpty,
            let raw = childDeviceID,
            !raw.isEmpty,
            let deviceID = UUID(uuidString: raw)
        else {
            return nil
        }
        return (deviceID: deviceID, token: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the simulator (no real APNs) and when the Push
        // Notifications capability/provisioning isn't configured. Log only.
        print("[AppDelegate] APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await CommandPoller.shared.pollOnceForCurrentDevice()
            completionHandler(.newData)
        }
    }
}
