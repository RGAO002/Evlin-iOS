import FamilyControls
import SwiftUI

/// Final child onboarding gate. Tracking and Parent PIN must both be usable
/// before the device reports onboarding complete.
struct ChildFinalSetupStep: View {
    // Background recovery still gets a bounded convergence window for durable
    // diagnostics. Finish no longer awaits this loop: Apple daemon readback is
    // eventually consistent and is not an onboarding completion boundary.
    static let finalActivationMaximumPasses = 60

    enum FinishFailure: Equatable {
        case missingDeviceIdentity
        case identityConvergence
        case lockTargets
        case defaultPool
        case v2Readiness

        var message: String {
            switch self {
            case .missingDeviceIdentity:
                return "This device's pairing identity is missing. Go back and pair it again."
            case .identityConvergence:
                return "Still clearing this device's previous setup. Keep Evlin open, then retry."
            case .lockTargets:
                return "App Controls hasn't finished syncing yet. Keep Evlin open, then tap Finish setup again."
            case .defaultPool:
                return "The family time pool isn't ready yet. Check the connection, then retry."
            case .v2Readiness:
                return "Screen Time monitoring isn't verified yet. Keep Evlin open, then retry."
            }
        }
    }

    struct IdentityTransitionSnapshot {
        let persistedOwner: UUID?
        let cleanupPending: Bool
    }

    let childDeviceID: UUID?
    let familyID: UUID?
    var kidName: String = ""
    let onEnter: () -> Void
    var onSingleDeviceContinue: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    @EnvironmentObject private var apiClient: APIClient
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @StateObject private var capture = TrackingSelectionCapture()
    @State private var pickerShown = false
    @State private var pinGateShown = false
    @State private var pinDone = false
    @State private var pinError: String?
    @State private var finishing = false
    @State private var finishError: String?

    private var trackingDone: Bool { capture.state == .saved }

    static func canFinish(trackingDone: Bool, pinDone: Bool) -> Bool {
        trackingDone && pinDone
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "6 · Final setup",
            stepIndex: 11,
            stepTotal: childTotal,
            title: "Two quick things and you're done",
            subtitle: "Both are needed before Evlin can start.",
            content: {
                VStack(spacing: Spacing.lg) {
                    trackingCard
                    pinCard
                    if let finishError {
                        Text(finishError)
                            .onboardingV2BodyXS()
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(
                    finishing ? "Finishing…" : "Finish setup",
                    role: .child
                ) {
                    Task { await finish() }
                }
                .disabled(
                    !Self.canFinish(
                        trackingDone: trackingDone,
                        pinDone: pinDone
                    ) || finishing
                )
                .opacity(
                    Self.canFinish(trackingDone: trackingDone, pinDone: pinDone)
                        ? 1 : 0.5
                )

                if !Self.canFinish(trackingDone: trackingDone, pinDone: pinDone) {
                    Text("Finish unlocks when both are done")
                        .onboardingV2BodyXS()
                }
                if let onBack {
                    OnboardingV2BackLink(action: onBack)
                }
            }
        )
        .familyActivityPicker(
            isPresented: $pickerShown,
            selection: $capture.selection
        )
        .onChange(of: pickerShown) { _, isOpen in
            guard !isOpen else { return }
            Task {
                await capture.commit {
                    _ = await recoverMeteringV2(
                        site: "onboarding.finalSetup.postSelection"
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $pinGateShown) {
            EvlinPINGateView(
                store: .shared,
                onUnlocked: {
                    pinGateShown = false
                    Task { await confirmPINAvailability() }
                },
                onCancel: { pinGateShown = false },
                onPINAuthenticated: { pin in
                    // Existing-PIN restores need the same backend convergence
                    // as a freshly-created PIN. Replays are idempotent.
                    ParentPINSyncCoordinator.captureNewPIN(pin)
                }
            )
        }
    }

    private var trackingCard: some View {
        taskCard(
            accent: OnboardingV2Theme.Palette.secondary,
            eyebrow: "SCREEN-TIME TRACKING",
            title: trackingDone ? "Tracking enabled" : "Turn on tracking",
            body: "Tap below and choose All Apps & Categories so Evlin can count screen time and award earned minutes.",
            done: trackingDone,
            problem: trackingProblem
        ) {
            AnyView(
                filledCardButton(
                    "Select All Apps & Categories",
                    systemImage: "square.grid.2x2",
                    tint: OnboardingV2Theme.Palette.secondary
                ) {
                    let approved = AuthorizationCenter.shared.authorizationStatus == .approved
                    pickerShown = capture.requestPicker(authorized: approved)
                }
            )
        }
    }

    private var trackingProblem: String? {
        switch capture.state {
        case .needsSelection:
            return "Choose at least one app or category before continuing."
        case .notAuthorized:
            return "Screen Time isn't authorized. Go back and finish that step first."
        default:
            return nil
        }
    }

    private var pinCard: some View {
        taskCard(
            accent: OnboardingV2Theme.Palette.tertiary,
            eyebrow: "EVLIN PARENT PIN",
            title: pinDone ? "Parent PIN saved" : "Hand the phone to your parent",
            body: "A parent creates a 4–8 digit PIN that locks Parent Controls on this phone. It is different from the iOS Screen Time passcode.",
            done: pinDone,
            problem: pinError
        ) {
            AnyView(
                outlinedCardButton(
                    pinError == nil ? "Create Parent PIN" : "Retry PIN sync",
                    systemImage: "lock",
                    tint: OnboardingV2Theme.Palette.tertiary
                ) {
                    pinError = nil
                    if EvlinPINStore.shared.isSet() {
                        Task { await confirmPINAvailability() }
                    } else {
                        pinGateShown = true
                    }
                }
            )
        }
    }

    /// Both cards read as one pattern: a dashed accent outline while the step is
    /// outstanding, a solid tinted card with a check once it is satisfied — so
    /// "what still needs doing" is legible at a glance rather than by reading.
    @ViewBuilder
    private func taskCard(
        accent: Color,
        eyebrow: String,
        title: String,
        body: String,
        done: Bool,
        problem: String?,
        @ViewBuilder action: () -> AnyView
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            Text(title)
                .font(OnboardingV2Theme.Typography.bodyStrong)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            Text(body).onboardingV2BodyXS()
            if let problem {
                Text(problem)
                    .onboardingV2BodyXS()
                    .foregroundStyle(OnboardingV2Theme.Palette.error)
            }
            if !done {
                action().padding(.top, Spacing.xs)
            }
        }
        .padding(OnboardingV2Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                style: .continuous
            )
            .fill(done ? accent.opacity(0.06) : OnboardingV2Theme.Palette.surfaceLowest)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                style: .continuous
            )
            .strokeBorder(
                accent.opacity(done ? 0.45 : 0.35),
                style: StrokeStyle(lineWidth: 1.5, dash: done ? [] : [5, 4])
            )
        )
        .animation(.easeOut(duration: 0.25), value: done)
    }

    private func filledCardButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta)
            .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint)
            )
        }
        .buttonStyle(.plain)
    }

    private func outlinedCardButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func confirmPINAvailability() async {
        if await ParentPINSyncCoordinator.ensureCurrentPINAvailable() {
            pinDone = true
            pinError = nil
        } else {
            pinError = "Couldn't save the Parent PIN. Retry."
        }
    }

    @discardableResult
    private func attemptMeteringV2Once(site: String) async -> Bool {
        guard let deviceID = childDeviceID,
              let baseURL = URL(string: apiClient.baseURL)
        else { return false }

        let outcome = await MeteringPolicyRefresh.now(
            childDeviceID: deviceID,
            baseURL: baseURL
        )
        guard outcome == .attempted else {
            MeteringFlightRecorder.emitFailure(
                site: site,
                verdict: "initial_v2_recovery_not_attempted",
                detail: MeteringFlightRecorder.detail([
                    ("device", deviceID.uuidString),
                    ("outcome", outcome.map { String(describing: $0) } ?? "failed"),
                ])
            )
            return false
        }
        return true
    }

    @discardableResult
    private func recoverMeteringV2(site: String) async -> Bool {
        guard let deviceID = childDeviceID,
              let baseURL = URL(string: apiClient.baseURL)
        else { return false }

        let evidence = await Self.awaitExactV2Readiness(
            maximumPasses: Self.finalActivationMaximumPasses,
            recover: {
                await MeteringPolicyRefresh.now(
                    childDeviceID: deviceID,
                    baseURL: baseURL
                )
            },
            readEvidence: {
                MeteringDaemonActivationEvidence.derive(
                    ownerChildDeviceID: deviceID,
                    state: try DeviceEpochStore.shared.read(),
                    entries: MeteringDaemonDiagnosticJournal().read()
                )
            },
            waitBeforeRetry: {
                try? await Task.sleep(for: .milliseconds(500))
            }
        )
        guard let evidence else {
            let lastEvidence = MeteringDaemonActivationEvidence.derive(
                ownerChildDeviceID: deviceID,
                state: try? DeviceEpochStore.shared.read(),
                entries: MeteringDaemonDiagnosticJournal().read()
            )
            MeteringFlightRecorder.emit(
                kind: .meteringError,
                site: site,
                verdict: "v2_activation_not_proven",
                detail: MeteringFlightRecorder.detail([
                    ("device", deviceID.uuidString),
                    ("stage", lastEvidence.stage.rawValue),
                    ("route", lastEvidence.routeLifecycle?.rawValue ?? "missing"),
                    ("install", lastEvidence.installPhase?.rawValue ?? "missing"),
                    ("activation_ack", String(lastEvidence.activationAcknowledged)),
                    ("daemon_readback", String(lastEvidence.exactDaemonReadback)),
                ])
            )
            return false
        }
        return Self.hasDurableV2Activation(evidence)
    }

    private func finish() async {
        finishing = true
        defer { finishing = false }
        finishError = nil
        let succeeded = await Self.runFinish(
            childDeviceID: childDeviceID,
            familyID: familyID,
            prepareMeteringConfiguration: { id in
                await prepareMeteringConfiguration(childDeviceID: id)
            },
            synchronizeLockTargets: { id in
                guard await AppControlsBackendSync.publishDefaultLockGroupIfNeeded(
                    for: id,
                    force: true
                ),
                let rawID = EarnedTimeStore.shared.lockedSetID,
                UUID(uuidString: rawID) != nil
                else { return false }
                return true
            },
            markAllSet: { id in
                await apiClient.markChildAllSet(childDeviceID: id)
            },
            recoverV2: {
                await attemptMeteringV2Once(
                    site: "onboarding.finalSetup.postAllSet"
                )
            },
            clearMatchingPendingAdoption: {
                guard let store = PendingAdoptionStore.shared(),
                      store.load()?.result?.childDeviceID == childDeviceID
                else { return }
                store.clear()
            },
            onFailure: { failure in
                finishError = failure.message
            }
        )
        guard succeeded else {
            if finishError == nil {
                finishError = "Couldn't finish setup. Retry."
            }
            return
        }
        if let onSingleDeviceContinue {
            onSingleDeviceContinue()
        } else {
            onboardingComplete = true
            onEnter()
        }
    }

    static func runFinish(
        childDeviceID: UUID?,
        familyID: UUID?,
        prepareMeteringConfiguration: (UUID) async -> Bool = { _ in true },
        synchronizeLockTargets: (UUID) async -> Bool = { _ in true },
        markAllSet: (UUID) async -> Bool,
        recoverV2: @escaping () async -> Bool,
        clearMatchingPendingAdoption: () -> Void = {},
        onFailure: (FinishFailure) -> Void = { _ in }
    ) async -> Bool {
        guard let childDeviceID else {
            onFailure(.missingDeviceIdentity)
            return false
        }
        guard await prepareMeteringConfiguration(childDeviceID) else {
            onFailure(.identityConvergence)
            return false
        }
        guard await synchronizeLockTargets(childDeviceID) else {
            onFailure(.lockTargets)
            return false
        }

        // Do not publish the command/poll identity until the App Group mirror
        // and DeviceEpochStore have converged. Publishing it first lets the
        // command poller run as the new device while cleanup still owns the
        // old metering root, recreating the three-identity split this gate is
        // intended to prevent.
        UserDefaults.standard.set(
            childDeviceID.uuidString,
            forKey: CommandPoller.childDeviceIDDefaultsKey
        )
        if let familyID {
            UserDefaults.standard.set(familyID.uuidString, forKey: "evlin.familyID")
        }
        guard await markAllSet(childDeviceID) else {
            onFailure(.defaultPool)
            return false
        }
        // The default pool only exists after all-set. Complete one real v2
        // recovery pass before leaving onboarding so an immediate force-quit
        // cannot cancel the first arm attempt. This does not wait for exact
        // daemon readback or activation; the normal owner loop keeps
        // converging those asynchronous acknowledgements.
        _ = await recoverV2()
        clearMatchingPendingAdoption()
        return true
    }

    static func convergeIdentityTransition(
        targetOwner: UUID,
        maximumPasses: Int,
        snapshot: () throws -> IdentityTransitionSnapshot,
        recoverCurrentCleanup: () async throws -> Void,
        mirrorTargetOwner: () throws -> Void,
        waitBeforeRetry: () async -> Void
    ) async -> Bool {
        do {
            var current = try snapshot()
            var passes = 0

            // A cleanup envelope owns the current root. Finish it before
            // asking the existing mirror state machine to begin another
            // transition, otherwise the newer pairing overwrites the only
            // durable path that can stop the older DAM activities.
            while current.cleanupPending && passes < maximumPasses {
                try await recoverCurrentCleanup()
                passes += 1
                await waitBeforeRetry()
                current = try snapshot()
            }
            guard !current.cleanupPending else { return false }

            if current.persistedOwner != targetOwner {
                try mirrorTargetOwner()
                current = try snapshot()
            }

            passes = 0
            while current.cleanupPending && passes < maximumPasses {
                try await recoverCurrentCleanup()
                passes += 1
                await waitBeforeRetry()
                current = try snapshot()
            }
            return !current.cleanupPending && current.persistedOwner == targetOwner
        } catch {
            return false
        }
    }

    static func awaitExactV2Readiness(
        maximumPasses: Int,
        recover: () async throws -> MeteringRecoveryOutcome?,
        readEvidence: () throws -> MeteringDaemonActivationEvidence,
        waitBeforeRetry: () async -> Void
    ) async -> MeteringDaemonActivationEvidence? {
        guard maximumPasses > 0 else { return nil }
        do {
            for pass in 0..<maximumPasses {
                guard try await recover() == .attempted else { return nil }
                let evidence = try readEvidence()
                if hasDurableV2Activation(evidence) { return evidence }
                if pass + 1 < maximumPasses {
                    await waitBeforeRetry()
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    static func hasDurableV2Activation(
        _ evidence: MeteringDaemonActivationEvidence
    ) -> Bool {
        evidence.advertisedVersion == 2
            && evidence.localSelection == .v2
            && evidence.epochID != nil
            && evidence.routeID != nil
            && evidence.routeLifecycle == .active
            && evidence.installPhase == .active
            && evidence.activationAcknowledged
    }

    private func prepareMeteringConfiguration(childDeviceID: UUID) async -> Bool {
        guard let baseURL = URL(string: apiClient.baseURL),
              let defaults = UserDefaults(
                suiteName: MeteringProductionComposition.appGroupSuiteName
              )
        else { return false }

        defaults.set(
            baseURL.absoluteString,
            forKey: MeteringProductionComposition.baseURLKey
        )

        // Finish any older adoption before beginning this pairing's identity
        // transition. The existing cleanup engine owns DAM stops, callback
        // invalidation, and the durable root replacement; this layer only
        // sequences it and refuses to advance while it remains incomplete.
        let converged = await Self.convergeIdentityTransition(
            targetOwner: childDeviceID,
            maximumPasses: 12,
            snapshot: {
                let state = try DeviceEpochStore.shared.read()
                return .init(
                    persistedOwner: state.ownerChildDeviceID,
                    cleanupPending: state.identityCleanupWork != nil
                )
            },
            recoverCurrentCleanup: {
                _ = try await MeteringProductionComposition
                    .recoverFromSharedConfiguration(role: .app)
            },
            mirrorTargetOwner: {
                EarnedBudgetArming.mirrorChildIdentity(
                    childDeviceID,
                    appGroupDefaults: defaults,
                    epochStore: .shared
                )
            },
            waitBeforeRetry: {
                try? await Task.sleep(for: .milliseconds(500))
            }
        )
        guard converged else {
            MeteringFlightRecorder.emitFailure(
                site: "onboarding.finalSetup.prepareMetering",
                verdict: "identity_cleanup_not_converged",
                detail: MeteringFlightRecorder.detail([
                    ("expected_owner", childDeviceID.uuidString),
                ])
            )
            return false
        }

        let mirroredOwner = defaults.string(
            forKey: MeteringProductionComposition.ownerKey
        ).flatMap(UUID.init(uuidString:))
        let mirroredBaseURL = defaults.string(
            forKey: MeteringProductionComposition.baseURLKey
        ).flatMap(URL.init(string:))
        let persistedOwner = try? DeviceEpochStore.shared.read().ownerChildDeviceID
        guard mirroredOwner == childDeviceID,
              persistedOwner == childDeviceID,
              Self.canonicalBaseURL(mirroredBaseURL) == Self.canonicalBaseURL(baseURL)
        else {
            MeteringFlightRecorder.emitFailure(
                site: "onboarding.finalSetup.prepareMetering",
                verdict: "pairing_configuration_readback_mismatch",
                detail: MeteringFlightRecorder.detail([
                    ("expected_owner", childDeviceID.uuidString),
                    ("mirrored_owner", mirroredOwner?.uuidString ?? "missing"),
                    ("persisted_owner", persistedOwner?.uuidString ?? "missing"),
                ])
            )
            return false
        }
        return true
    }

    private static func canonicalBaseURL(_ url: URL?) -> String? {
        url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }
}
