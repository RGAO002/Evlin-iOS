import SwiftUI
import FamilyControls
import UIKit
import Sentry
import os

@main
struct Evlin_iOSApp: App {
    /// Bridges UIKit's app-delegate callbacks into our SwiftUI lifecycle —
    /// specifically APNs registration and silent (`content-available:1`)
    /// remote-push delivery, which have no SwiftUI-native equivalent. See
    /// `AppDelegate` below.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var apiClient = APIClient()
    @StateObject private var screenTimeManager = ScreenTimeManager.shared

    /// Parent Home single-source-of-truth (spec §6.1). Built lazily from the
    /// shared `APIClient` so authed reads share the session. `FamilyStore` is
    /// `@Observable @MainActor`, so it is injected via `.environment(...)`
    /// (not `@StateObject`) and held here so it survives view rebuilds.
    @State private var familyStore: FamilyStore? = nil

    /// Tracks lifecycle so CommandPoller can start/stop with the scene.
    @Environment(\.scenePhase) private var scenePhase

    /// Mirrors FloatingModeToggle's storage so we can flip the poller on
    /// every parent↔child mode switch (single-device dev). On real
    /// two-device deployments the parent device never has
    /// `evlin.childDeviceID` set, so the guard inside is moot.
    @AppStorage("appMode") private var appMode: String = ""

    /// Mirrors the key ChildReadyStep / DoneStep / OnboardingCoordinator write
    /// when onboarding finishes. Without observing this, a kid device that
    /// completes v2 onboarding sits foregrounded with CommandPoller stopped —
    /// `startPollerIfPaired()` was only re-evaluated on .onAppear, scenePhase,
    /// and appMode changes, none of which fire at onboarding completion.
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("evlin.childDeviceID") private var childDeviceID: String = ""
    @AppStorage(AppDelegate.parentDeviceIDDefaultsKey) private var parentDeviceID: String = ""

    init() {
        // Restore the device identity from its Keychain mirror before anything
        // reads it, so a reinstall re-attaches to the same backend device
        // instead of minting a fresh id and losing usage. See DeviceIdentity.
        DeviceIdentity.shared.hydrate()
        // One-shot migration from legacy evlin.activeLocks store.
        // Pre-launch, so safe to drop legacy data. See plan Phase 11.
        ActiveLockMigration.runIfNeeded()
        // Publish the Evlin app icon into the shared App Group so the
        // EvlinShieldConfig lock screen can render it (the extension can't
        // read this app's asset catalog). Versioned + cheap.
        EvlinShieldIconPublisher.publish()
        // When a recovery pass swaps the active route (reflection/task resume
        // mints a fresh one), file the first watchdog verdict immediately —
        // the 5-min throttle would otherwise leave the parent on SYNCING
        // until the next check or the first settled sample (~10 min).
        AppMeteringEntry.shared.onActiveRouteChanged = { _ in
            await MeteringWatchdog.shared.run(trigger: "route_change")
        }
    }

    var body: some Scene {
        WindowGroup {
            // TEMP UI HARNESS (DEBUG only): boot straight into ChatView with
            // seeded messages so the chat surface can be driven in a bare
            // simulator without auth. Activated via env var, never in release.
            #if DEBUG
            if ProcessInfo.processInfo.environment["EVLIN_UI_HARNESS"] == "chat" {
                ChatHarnessRoot()
                    .preferredColorScheme(.light)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
    }

    private var mainContent: some View {
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
                // Google Sign-In OAuth redirect (via the reversed-client-id URL
                // scheme). No-op until the GoogleSignIn SPM package is linked.
                .onOpenURL { GoogleSignInCoordinator.handleURL($0) }
                .environmentObject(apiClient)
                .environmentObject(screenTimeManager)
                .environment(familyStore ?? FamilyStore(api: apiClient))
                .task {
                    // Build the store once off the shared APIClient and load
                    // the family aggregate (GET /me/profile). No-op / .failed
                    // when not signed in — Home then renders its empty state.
                    if familyStore == nil { familyStore = FamilyStore(api: apiClient) }
                    await familyStore?.load()
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard KeyboardDismissGate.shouldDismissKeyboardForRootTap() else { return }
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
                .onAppear {
                    Task { await ParentPINSyncCoordinator.runForeground() }
                    refreshParentPushRegistrationIfNeeded()
                    refreshChildPushRegistrationIfNeeded()
                    startPollerIfPaired()
                    armEarnedBudgetIfReady()
                    recoverMeteringEpochIfReady()
                    if appMode == "child" {
                        Task { await AppLimitRecoveryTrigger.launch() }
                    }
                    drainEarnedSampleRetryQueueIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await ParentPINSyncCoordinator.runForeground() }
                        refreshParentPushRegistrationIfNeeded()
                        refreshChildPushRegistrationIfNeeded()
                        startPollerIfPaired()
                        armEarnedBudgetIfReady()
                        recoverMeteringEpochIfReady()
                        if appMode == "child" {
                            Task { await AppLimitRecoveryTrigger.foreground() }
                        }
                        drainEarnedSampleRetryQueueIfNeeded()
                        Task { await ScreenTimeEventUploader.uploadPending() }
                    case .background:
                        startBackgroundPollerIfPaired()
                        DeviceIdentity.shared.capture()
                        // Flush on the way out, not only on the way in: the
                        // lines written during this session are the ones that
                        // explain whatever happens while the app is away.
                        Task { await ScreenTimeEventUploader.uploadPending() }
                    case .inactive:
                        break
                    @unknown default: break
                    }
                }
                .onChange(of: appMode) { _, newValue in
                    // Toggling P↔K starts/stops the poller — see the
                    // doc on startPollerIfPaired for why.
                    AppDelegate.handleChildDeviceIDAvailability(
                        childDeviceID,
                        appMode: newValue,
                        using: apiClient
                    )
                    refreshParentPushRegistrationIfNeeded(appMode: newValue)
                    startPollerIfPaired()
                }
                .onChange(of: onboardingComplete) { _, complete in
                    // Kid finishes v2 onboarding → ChildReadyStep has already
                    // persisted `evlin.childDeviceID` (strictly before flipping
                    // this flag), so the guard inside reads fresh keys and the
                    // CommandPoller starts immediately — no background+reopen
                    // round-trip required for parent commands to land.
                    if complete { startPollerIfPaired() }
                }
                .onChange(of: childDeviceID) { _, newValue in
                    AppDelegate.handleChildDeviceIDAvailability(
                        newValue,
                        appMode: appMode,
                        using: apiClient
                    )
                    startPollerIfPaired()
                }
                .onChange(of: parentDeviceID) { _, _ in
                    refreshParentPushRegistrationIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
                    // Demo bootstrap (or parent approve) can rewrite `evlin.childDeviceID` while
                    // already in K mode — restart polling with the fresh UUID.
                    startPollerIfPaired()
                }
    }

    private func refreshParentPushRegistrationIfNeeded(appMode explicitMode: String? = nil) {
        let mode = explicitMode ?? appMode
        guard mode == "parent" else { return }
        AppDelegate.requestNotificationAuthorizationIfNeeded()
        AppDelegate.uploadCachedAPNsTokenIfPossible(using: apiClient)
    }

    private func refreshChildPushRegistrationIfNeeded(appMode explicitMode: String? = nil) {
        AppDelegate.handleForegroundAPNsRegistration(
            appMode: explicitMode ?? appMode,
            using: apiClient
        )
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
    /// next polls").
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

    /// Arm the earned-budget ladder scheduler when the child device is active and
    /// `EarnedTimeStore` reports readiness (measurement selection + locked-set ID
    /// both present). No-op when not ready or when running in parent mode.
    /// The shared implementation also tears down state left behind by a
    /// previous device identity (account/family switch).
    /// Unstructured on purpose: this is called from scene-activation handlers
    /// that are not async, and `armIfReady` now hops its DeviceActivity calls
    /// off the main thread. Awaiting it here would mean making every one of
    /// those handlers async to gain nothing — the arm reports its own outcome to
    /// diagnostics and no caller consumes a result.
    private func armEarnedBudgetIfReady() {
        Task { await EarnedBudgetArming.armIfReady() }
    }

    private func drainEarnedSampleRetryQueueIfNeeded() {
        guard appMode == "child" else { return }
        Task {
            await EarnedSampleReporter.drainRetryQueueFromStoredConfig()
        }
    }

    private func recoverMeteringEpochIfReady() {
        guard appMode == "child" else { return }
        Task { @MainActor in
            await AppMeteringEntry.shared.recoverIfConfigured()
            // A3 watchdog. Runs after the recovery pass so it judges the state
            // recovery just produced, and is internally throttled (≥5 min
            // between checks, ≥10 min between auto re-kicks) — this is called
            // on both `onAppear` and every `.active` scene transition.
            await MeteringWatchdog.shared.runIfDue(trigger: "foreground")
        }
    }

    /// When the kid device backgrounds Evlin, keep polling briefly using iOS's
    /// background-task grace window. This does not survive user force-quit, but
    /// it does cover ordinary background / screen-lock transitions without
    /// requiring the kid to reopen Evlin immediately.
    private func startBackgroundPollerIfPaired() {
        guard UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
                .flatMap(UUID.init(uuidString:)) != nil
        else { return }
        let appMode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard appMode == "child" else {
            CommandPoller.shared.stop()
            return
        }
        CommandPoller.shared.startBackgroundGracePolling()
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
///      the app isn't foregrounded. The same wake also invalidates BigKid
///      state so reflection assignments apply immediately.
///
/// Note: real APNs on a physical device additionally needs the Push
/// Notifications capability (the `aps-environment` entitlement) + a
/// provisioning profile. That's a device-signing step; the code and the
/// `UIBackgroundModes: remote-notification` Info.plist key compile and run on
/// the simulator without it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// UserDefaults key for the most-recent hex-encoded APNs device token.
    /// Cached unconditionally on `didRegister...` so a token that arrives
    /// before pairing isn't lost — `uploadCachedAPNsTokenIfPossible()` (and
    /// the pairing hook in ContentView) replay it once `childDeviceID` exists.
    static let apnsDeviceTokenDefaultsKey = "evlin.apnsDeviceToken"

    /// UserDefaults key for THIS device's *own* parent Device-row id (written on
    /// parent pairing). A parent device uploads its APNs token to this row so
    /// parent-audience feed pushes (reflection-complete, lock-delay, device
    /// offline, …) can be delivered. Distinct from `evlin.childDeviceID`, which
    /// on a parent device holds the *kid's* remote device id (chat targeting).
    static let parentDeviceIDDefaultsKey = "evlin.parentDeviceID"

    /// Dedicated client for token upload. Reads the same persisted `serverURL`
    /// as the app's `@StateObject` client, so it targets the same backend.
    private let apiClient = APIClient()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Error monitoring (Sentry). No-op unless SENTRY_DSN is set in Info.plist;
        // COPPA-safe (no default PII, user dropped before send).
        let sentryDSN = (Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String) ?? ""
        if !sentryDSN.isEmpty {
            SentrySDK.start { options in
                options.dsn = sentryDSN
                options.environment = (Bundle.main.object(forInfoDictionaryKey: "SENTRY_ENVIRONMENT") as? String) ?? "development"
                options.sendDefaultPii = false
                options.tracesSampleRate = 0.1
                options.beforeSend = { event in
                    event.user = nil
                    return event
                }
            }
        }

        // Ask iOS for an APNs token. The result arrives asynchronously in
        // didRegister.../didFailToRegister... below. Safe to call every
        // launch; iOS coalesces and returns the cached token quickly.
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate (notif spec §1.5 / Phase 3)

    /// Present Evlin alerts as banners even while the app is foregrounded so a
    /// lock / receipt notification isn't silently swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AppDelegate.invalidateRemoteNotificationDrivenStores()
        completionHandler([.banner, .list, .sound])
    }

    /// A tapped notification brings the app forward. If the APNs payload
    /// carries a backend event id, ParentRootView refreshes the bell feed and
    /// routes that exact event; otherwise fall back to the bell.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        NotificationCenter.default.post(name: .evlinNotificationFeedInvalidated, object: nil)
        if let eventID = Self.notificationEventID(from: userInfo) {
            PendingNotificationOpenStore().save(eventID)
            NotificationCenter.default.post(
                name: .evlinOpenNotificationEvent,
                object: nil,
                userInfo: ["event_id": eventID]
            )
        } else {
            NotificationCenter.default.post(name: .evlinOpenNotifications, object: nil)
        }
        completionHandler()
    }

    static func notificationEventID(from userInfo: [AnyHashable: Any]) -> String? {
        if let evlin = userInfo["evlin"] as? [String: Any],
           let eventID = evlin["event_id"] as? String,
           !eventID.isEmpty {
            return eventID
        }
        if let evlin = userInfo["evlin"] as? [AnyHashable: Any],
           let eventID = evlin["event_id"] as? String,
           !eventID.isEmpty {
            return eventID
        }
        if let eventID = userInfo["event_id"] as? String, !eventID.isEmpty {
            return eventID
        }
        return nil
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
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyTokenRegistered,
            CommandDeliveryDiagnostics.tokenSummary(token)
        )
        AppDelegate.uploadCachedAPNsTokenIfPossible(using: apiClient)
    }

    /// Ask iOS for permission to DISPLAY alerts/sounds/badges.
    ///
    /// `registerForRemoteNotifications()` only obtains an APNs token — it does
    /// NOT grant permission to show banners. Without this call APNs accepts the
    /// push (HTTP 200) but iOS silently drops the banner. The kid onboarding
    /// already requests this; the PARENT app never did, so parent-audience feed
    /// pushes (reflection-complete, lock-delay, …) were delivered-but-invisible.
    /// Idempotent: after the first prompt iOS returns the existing decision.
    static func requestNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
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
        let appMode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        let childID = UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey)
        let parentID = UserDefaults.standard.string(forKey: parentDeviceIDDefaultsKey)
        guard let upload = apnsTokenUploadPlan(
            cachedToken: cached, appMode: appMode,
            childDeviceID: childID, parentDeviceID: parentID
        ) else {
            CommandDeliveryDiagnostics.record(
                CommandDeliveryDiagnostics.keyTokenUpload,
                "skipped mode=\(appMode.isEmpty ? "?" : appMode) cached=\(cached?.isEmpty == false ? "yes" : "no") child_id=\(childID?.isEmpty == false ? "yes" : "no") parent_id=\(parentID?.isEmpty == false ? "yes" : "no")"
            )
            return
        }
        Task {
            do {
                switch upload.route {
                case .childRegisterAPNs:
                    try await apiClient.registerAPNsToken(deviceID: upload.deviceID, token: upload.token)
                case .familyDeviceRegister:
                    try await apiClient.registerParentAPNsToken(deviceID: upload.deviceID, token: upload.token)
                }
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyTokenUpload,
                    "ok route=\(upload.route.rawValue) device=\(upload.deviceID.uuidString) \(CommandDeliveryDiagnostics.tokenSummary(upload.token))"
                )
            } catch {
                CommandDeliveryDiagnostics.record(
                    CommandDeliveryDiagnostics.keyTokenUpload,
                    "failed route=\(upload.route.rawValue) device=\(upload.deviceID.uuidString) error=\(error.localizedDescription)"
                )
                print("[AppDelegate] APNs token upload failed: \(error)")
                SentrySDK.capture(error: error)
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

    /// Mode-aware overload: route the cached APNs token to the backend Device
    /// row THIS physical device OWNS.
    ///
    /// A parent device (`appMode == "parent"`) uploads to its own
    /// `parentDeviceID`. It must NOT upload to `childDeviceID`, which on a parent
    /// device holds the *kid's* remote device id (kept for chat targeting) —
    /// uploading there would overwrite the kid's lock-delivery token and break
    /// force-quit locks. `"child"` and pre-pairing (`"setup"` / `""`) keep the
    /// legacy `childDeviceID` path. Delegates to the single-id resolver so all
    /// its validation (and its tests) still apply.
    static func shouldUploadAPNsToken(
        cachedToken: String?,
        appMode: String,
        childDeviceID: String?,
        parentDeviceID: String?
    ) -> APNsTokenUploadPlan? {
        apnsTokenUploadPlan(
            cachedToken: cachedToken,
            appMode: appMode,
            childDeviceID: childDeviceID,
            parentDeviceID: parentDeviceID
        )
    }

    enum APNsTokenUploadRoute: String, Equatable {
        case childRegisterAPNs
        case familyDeviceRegister
    }

    struct APNsTokenUploadPlan: Equatable {
        let deviceID: UUID
        let token: String
        let route: APNsTokenUploadRoute
    }

    static func apnsTokenUploadPlan(
        cachedToken: String?,
        appMode: String,
        childDeviceID: String?,
        parentDeviceID: String?
    ) -> APNsTokenUploadPlan? {
        let ownDeviceID = appMode == "parent" ? parentDeviceID : childDeviceID
        guard let upload = shouldUploadAPNsToken(cachedToken: cachedToken, childDeviceID: ownDeviceID) else {
            return nil
        }
        let route: APNsTokenUploadRoute = appMode == "parent" ? .familyDeviceRegister : .childRegisterAPNs
        return APNsTokenUploadPlan(deviceID: upload.deviceID, token: upload.token, route: route)
    }

    /// Called whenever the app learns or re-learns the paired child device id.
    ///
    /// This fixes the reinstall/pairing race where APNs registration succeeds
    /// before `evlin.childDeviceID` exists: the token is cached, but there was
    /// no reliable kid-side replay once pairing completed. Only child mode may
    /// upload to `/child/register-apns`; parent devices also store a child id
    /// for chat targeting and must not overwrite the kid device's APNs token.
    static func handleChildDeviceIDAvailability(
        _ rawChildDeviceID: String,
        appMode: String,
        using apiClient: APIClient
    ) {
        handleChildDeviceIDAvailability(
            rawChildDeviceID,
            appMode: appMode,
            uploadCachedToken: { uploadCachedAPNsTokenIfPossible(using: apiClient) }
        )
    }

    /// Replays the cached child token on every foreground entry. This repairs a
    /// backend token cleared after APNs reported BadDeviceToken without waiting
    /// for another pairing transition or a fresh token callback from iOS.
    static func handleForegroundAPNsRegistration(
        appMode: String,
        using apiClient: APIClient
    ) {
        handleForegroundAPNsRegistration(
            appMode: appMode,
            uploadCachedToken: { uploadCachedAPNsTokenIfPossible(using: apiClient) }
        )
    }

    static func handleForegroundAPNsRegistration(
        appMode: String,
        uploadCachedToken: () -> Void,
        registerForRemoteNotifications: () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        }
    ) {
        guard appMode == "child" else { return }
        uploadCachedToken()
        registerForRemoteNotifications()
    }

    static func handleChildDeviceIDAvailability(
        _ rawChildDeviceID: String,
        appMode: String,
        uploadCachedToken: () -> Void,
        registerForRemoteNotifications: () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        }
    ) {
        guard shouldReplayAPNsForChildDeviceID(rawChildDeviceID, appMode: appMode) else { return }
        uploadCachedToken()
        registerForRemoteNotifications()
    }

    static func shouldReplayAPNsForChildDeviceID(
        _ rawChildDeviceID: String,
        appMode: String
    ) -> Bool {
        appMode == "child" && UUID(uuidString: rawChildDeviceID) != nil
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the simulator (no real APNs) and when the Push
        // Notifications capability/provisioning isn't configured. Log only.
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyTokenRegistered,
            "failed error=\(error.localizedDescription)"
        )
        print("[AppDelegate] APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        CommandDeliveryDiagnostics.record(
            CommandDeliveryDiagnostics.keyRemoteNotification,
            "received content_available=\(aps?["content-available"] ?? "unknown") keys=\(userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","))"
        )
        let executionBudget = MeteringRecoveryExecutionBudget()
        let backgroundTaskID = application.beginBackgroundTask(
            withName: "EvlinMeteringRecovery"
        ) {
            executionBudget.expire()
            os_log(
                .error,
                "Metering background recovery expired; new persistent transactions are disabled"
            )
        }
        Task { @MainActor in
            defer {
                if backgroundTaskID != .invalid {
                    application.endBackgroundTask(backgroundTaskID)
                }
            }
            await MeteringRecoveryExecutionContext.$budget.withValue(executionBudget) {
                AppDelegate.invalidateRemoteNotificationDrivenStores()
                await CommandPoller.shared.pollOnceForCurrentDevice(
                    recoveryReason: .silentRemoteNotification
                )
                // #96: a silent wake is the backend's only way to reach a closed
                // app. The state-invalidated broadcast above only helps when a
                // foreground poller is alive to hear it — in a background wake
                // nothing is. Run one explicit metering recovery pass so a
                // starving device re-paves its dated horizon, finishes wedged
                // work, and crosses midnight without the kid opening the app.
                _ = try? await MeteringProductionComposition.recoverFromSharedConfiguration(
                    role: .app
                )
                // Per-app owner recovery rides the same wake. The earned pool got
                // this leg with #96; per-app was left off it, so a `set_limit`
                // ingested here sat as `accepted_needs_owner` until someone opened
                // Evlin — the "must open the app to arm a limit" complaint of
                // 2026-08-07, twice on real hardware (iPhone 02:44, iPad 05:41).
                await AppLimitRecoveryTrigger.foreground()
                // Watchdog on the same wake: reds (revoked authorization, stuck
                // handoffs) otherwise wait for a foreground that may be days out.
                // The hourly starvation kick makes this a steady background pulse.
                await MeteringWatchdog.shared.runIfDue(trigger: "background_push")
                // The backend's rejected-burst lane means callbacks are dying
                // against a dead epoch RIGHT NOW. A maintenance pass finds a green
                // watchdog and does nothing (2026-08-11, post-19:29: armed, green,
                // stone dead — the day's one-shot thresholds had already burned).
                // Only a re-arm resets Apple's counter and re-exposes the rungs,
                // so this wake kind forces one explicitly.
                if let evlin = userInfo["evlin"] as? [AnyHashable: Any],
                   evlin["kind"] as? String == "metering_rearm" {
                    _ = await MeteringTodayRouteRekick.run(trigger: "rejected_burst_kick")
                }
                // Ship the flight recorder too. Until now `uploadPending` had a
                // single call site — the foreground scene transition — so the
                // black box was blind for exactly the stretches worth diagnosing:
                // whenever the kid was not looking at Evlin. Samples and command
                // acks always flowed in the background; the diagnostics did not.
                await ScreenTimeEventUploader.uploadPending()
                completionHandler(.newData)
            }
        }
    }

    @MainActor
    static func invalidateRemoteNotificationDrivenStores() {
        NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        NotificationCenter.default.post(name: .evlinNotificationFeedInvalidated, object: nil)
    }
}

/// Publishes the Evlin app icon into the shared App Group so the
/// `EvlinShieldConfig` lock-screen extension can render it.
///
/// The extension can't read the main app's asset catalog (extensions have their
/// own bundle), and inside that specific extension only App Group *UserDefaults*
/// is reliable — its App Group file + Keychain writes are sandbox-blocked (the
/// old "E1 probe" proved `UD=rtok` but `file=…`/`KC=…` failed). So we hand the
/// icon across as PNG `Data` in UserDefaults. Versioned + cheap: it only
/// rewrites when the bundled icon version changes.
enum EvlinShieldIconPublisher {
    static let appGroup = "group.com.evlin.ios"
    static let dataKey = "evlin.shield.icon"
    static let versionKey = "evlin.shield.icon.v"
    /// Bump when the bundled `EvlinShieldIcon` artwork changes (or its size)
    /// so devices re-publish the new image. (2 = mascot; 3 = larger mascot.)
    static let version = 3
    /// Mascot width in the published image (points). The extension reloads at
    /// scale 2, so this renders ~120pt wide on the shield. Increase to make the
    /// mascot bigger.
    private static let mascotWidth: CGFloat = 240
    /// Transparent strip baked BELOW the mascot. ShieldConfiguration has no
    /// spacing API, so this padding is how we get air between the icon and the
    /// title — but it also shrinks the mascot's share of the icon box, so keep
    /// it small when a big mascot matters more than the gap.
    private static let bottomPadding: CGFloat = 28

    static func publish() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        if defaults.integer(forKey: versionKey) == version,
           defaults.data(forKey: dataKey) != nil {
            return
        }
        guard let source = UIImage(named: "EvlinShieldIcon") else { return }
        // Preserve the mascot's (portrait) aspect ratio, then add a transparent
        // strip below it for icon↔title breathing room.
        let aspect = source.size.width / max(source.size.height, 1)
        let mascotHeight = (mascotWidth / max(aspect, 0.01)).rounded()
        let canvas = CGSize(width: mascotWidth, height: mascotHeight + bottomPadding)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: mascotWidth, height: mascotHeight))
        }
        guard let data = rendered.pngData() else { return }
        defaults.set(data, forKey: dataKey)
        defaults.set(version, forKey: versionKey)
    }
}

extension Notification.Name {
    static let evlinOpenNotifications = Notification.Name("evlin.openNotifications")
    static let evlinOpenNotificationEvent = Notification.Name("evlin.openNotificationEvent")
    static let evlinNotificationFeedInvalidated = Notification.Name("evlin.notificationFeedInvalidated")
}

#if DEBUG
/// TEMP UI HARNESS: bare ChatView with seeded messages for simulator-driven
/// hit-testing. No auth, no network expectations (sends will fail politely).
private struct ChatHarnessRoot: View {
    @StateObject private var api = APIClient()
    @StateObject private var vm = ChatViewModel()
    @State private var reflection = ParentReflectionFixtureStore()
    @State private var family: FamilyStore

    init() {
        let client = APIClient()
        _api = StateObject(wrappedValue: client)
        _family = State(initialValue: FamilyStore(api: client))
    }

    var body: some View {
        ChatView(viewModel: vm)
            .environmentObject(api)
            .environment(reflection)
            .environment(family)
            .onAppear {
                guard vm.messages.isEmpty else { return }
                for i in 0..<60 {
                    vm.messages.append(ChatMessage(
                        role: i % 2 == 0 ? .parent : .agent,
                        content: "Harness message #\(i) — enough text to take a couple of lines and make the list scroll properly.",
                        timestamp: Date().addingTimeInterval(Double(i - 60) * 60)
                    ))
                }
            }
    }
}
#endif
