import SwiftUI
import UIKit

enum OnboardingStep: Equatable {
    case welcome
    case modeSelect

    // DEBUG-only: choose Local vs Production backend BEFORE pairing.
    // In Release builds this case still exists for enum completeness but
    // is never set — `modeSelect.onSelect` skips straight to the pairing
    // step. Release pairings always hit Production.
    case backendChoice

    // Parent flow
    case parentAddChild
    case parentProtectionLevel
    case parentPairingCode
    case parentMaxWhyChildAppleID
    case parentMaxCreateChildAppleID
    case parentMaxSignInOnChild
    case parentMaxWaitForAuth
    case parentStdSetPasscode
    case parentFirstSavedList      // Max only
    case parentDone

    // Child flow
    case childEnterPairingCode
    case childGrantPermission
    case childDeletionProtection
    case childCategoryDefaults
    case childFirstSavedList        // Std only
    case childReady

    // MARK: - Onboarding v2 (scaffold)
    //
    // New v2 screen sequence per design spec §7 (2026-06-06-onboarding-v2-design.md).
    // These are the *primary* path going forward; the cases above are kept for
    // compatibility (old flow + Max "Advanced" block reachable from Settings).
    // Case spellings match spec §7 verbatim. Several existing cases are REUSED
    // by the v2 chain rather than duplicated: `welcome`, `modeSelect`,
    // `parentPairingCode`, `parentDone`, `childGrantPermission`,
    // `childDeletionProtection`, `childReady`.

    // v2 Parent flow (new cases)
    case parentSignIn            // mockup 3: "Create your parent account"
    case parentProfile           // mockup 4: "Tell us about you"
    case parentNewOrJoin         // mockup 5: "New family — or join an existing one"
    case parentCoParentJoin      // Plan 5: co-parent "waiting for owner approval" poll
    case parentBackInInstantly   // Plan 8: returning-parent / approved-co-parent recovery
    case parentPairScan          // mockup 6: "Scan the kid's code" (QR + 6-digit fallback)
    case parentConnected         // mockup 7: "Connected" (parent side)
    case parentWaitingForKid     // polls /family/pairing-status kid_onboarding_phase
    case parentSetPasscode       // mockup 14: "Lock the Screen Time settings"
    case parentFirstActions      // mockup 15: "Send your first block (test)"
    case parentItWorks           // mockup 16: "It works — the test pays off"
    case parentTryReflection     // P2: separate reflection demo (auto-clears at setup end)

    // v2 Kid flow (new cases)
    case childProfile            // mockup 3 (kid): "Set up your profile"
    case childShowCode           // mockup 5/6 (kid): "Show this to your parent"
    case childConnected          // mockup 7 (kid): "You're linked to your parent"
    case childConsentDisclosure  // mockup 8: "What Evlin can see"
    case childAllowNotifications // mockup 10: "Allow notifications"
    case childLockableHub        // mockup 12: "Choose what Evlin can lock"
}

struct OnboardingCoordinator: View {

    @EnvironmentObject var apiClient: APIClient

    /// Parent Home single-source-of-truth, injected by Evlin_iOSApp via
    /// `.environment(...)`. After a successful /family/pair we call
    /// `familyStore.load()` so Home renders the freshly-bound family.
    @Environment(FamilyStore.self) private var familyStore

    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    @State private var step: OnboardingStep = .welcome

    // Onboarding v2 — authed parent session. `AuthService` is `@MainActor
    // @Observable` and is NOT injected app-wide (it has no environment owner
    // yet), so the coordinator builds ONE off the shared `APIClient` and threads
    // it into the v2 parent screens. `restore()` rehydrates any Keychain session
    // (a returning parent who relaunches mid-onboarding stays signed in).
    @State private var auth: AuthService? = nil
    /// P2: the exact app (from the kid's lockable catalog) the parent's first
    /// block targets — resolved by the readiness poll on parentWaitingForKid.
    @State private var firstBlockApp: ChildReadinessDTO.App? = nil

    // Onboarding v2 (scaffold): when true, `modeSelect` routes into the v2
    // screen sequence (spec §7) instead of the legacy pairing-first flow.
    // Defaults to true so the v2 chain is the DEFAULT next-path. The legacy
    // path stays reachable by flipping this off (DEBUG ladybug menu).
    @State private var useV2Flow: Bool = true

    // Shared state threaded between steps
    @State private var childName: String = ""
    // Default "std" (was "max"). Onboarding order is now Pair → ProtectionLevel,
    // so this default is what /family/pair gets on the wire when the parent
    // hasn't picked yet. Std is the conservative choice: no Apple-ID dependency,
    // no fail-closed cascade. ProtectionLevelStep PUTs the family if the
    // parent ultimately picks Max.
    @State private var protectionMode: String = "std"
    @State private var pairingCode: String = ""
    @State private var familyID: UUID? = nil
    @State private var parentDeviceID: UUID? = nil
    @State private var childDeviceID: UUID? = nil

    // MARK: - Onboarding v2 threaded state (parent pairing)
    //
    // Populated by the v2 parent screens as the flow progresses, then read by
    // later screens (parentConnected shows `kidName`). `kidName` is resolved
    // from FamilyStore after the pair binds the family (the pair response
    // itself carries only ids); `pairedChildDeviceID` is the child device the
    // consumed code belonged to (also persisted to UserDefaults by the pair
    // handler, mirroring legacy PairingCodeStep).
    @State private var kidName: String = ""
    @State private var pairedChildDeviceID: UUID? = nil

    // MARK: - Onboarding v2 threaded state (KID create + profile)
    //
    // The KID device collects its profile LOCALLY (childProfileName /
    // childBirthYear / childGender) on `childProfile`, then on `childShowCode`
    // calls POST /family/create to mint the family + child device + 6-digit code
    // (childPairingCode). The kid is unauthenticated, so there is no /me/profile
    // to write to here — the captured profile is threaded forward and persisted
    // to UserDefaults so the post-onboarding kid shell + any later child-create
    // can read it (the parent, once paired, owns the real child profile write).
    @State private var childProfileName: String = ""
    @State private var childBirthYear: Int? = nil
    @State private var childGender: String? = nil
    @State private var childPairingCode: String = ""

    // MARK: - Onboarding v2 threaded state (co-parent join — Plan 5)
    //
    // The invite code the co-parent consumed (uppercased) + whether the consume
    // returned `pending_approval`. Used by the join + recovery branches.
    @State private var coParentInviteCode: String = ""

    /// Plan 8 — true when the signed-in account ALREADY has a family bound
    /// (returning parent on a new device, or an already-bound co-parent). Read
    /// off the AuthService session (needs_family == false → familyID != nil).
    /// Drives the `parentSignIn` recovery branch.
    private var parentHasExistingFamily: Bool {
        auth?.account?.familyID != nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            stepBody
                .task {
                    // Build the authed parent session ONCE off the shared
                    // APIClient and rehydrate any stored Keychain session.
                    if auth == nil {
                        let svc = AuthService(api: apiClient)
                        svc.restore()
                        auth = svc
                    }
                }
                #if DEBUG
                // Single-device "jump to parent" shortcut. EnterPairingCodeStep
                // (child side) posts this when the dev taps the "switch to
                // parent + auto-fill code" button. We flip the role + jump
                // straight to the parent-side code-entry step; the code
                // itself is in UserDefaults `evlin.dev.pendingPairingCode`
                // and PairingCodeStep auto-fills it from there.
                .onReceive(NotificationCenter.default.publisher(
                    for: .evlinSingleDeviceJumpToParent,
                )) { _ in
                    appMode = "parent"
                    // v2 retargets the single-device jump to the parent pair
                    // step (spec §7.4); v1 lands on the code-entry step.
                    step = useV2Flow ? .parentPairScan : .parentPairingCode
                }
                #endif

            #if DEBUG
            // Debug escape hatch — always available during onboarding
            Menu {
                // ── Onboarding v2 (scaffold) tap-through entries ──
                // Jump straight into the FIRST v2 screen for each role so a
                // human can tap "Continue" through the entire v2 sequence
                // end-to-end without pairing. `useV2Flow` is already the
                // default, so these just set the role + first step.
                Button("▶︎ v2 PARENT flow (tap-through)") {
                    useV2Flow = true
                    appMode = "parent"
                    step = .parentSignIn
                }
                Button("▶︎ v2 KID flow (tap-through)") {
                    useV2Flow = true
                    appMode = "child"
                    step = .childProfile
                }
                Button("Use LEGACY v1 flow") {
                    useV2Flow = false
                    step = .welcome
                }

                Divider()

                Button("Skip to Parent mode (test)") {
                    EvlinDemoShortcuts.enable()
                    EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
                    appMode = "parent"
                    onboardingComplete = true
                    EvlinDemoShortcuts.scheduleBackendDemoPairingIfNeeded()
                }
                Button("Skip to Child mode (test)") {
                    EvlinDemoShortcuts.enable()
                    appMode = "child"
                    UserDefaults.standard.set(
                        OnboardingDemoPlaceholders.childDeviceUUIDString,
                        forKey: "evlin.childDeviceID"
                    )
                    onboardingComplete = true
                    EvlinDemoShortcuts.scheduleBackendDemoPairingIfNeeded()
                }
                Button("Reset everything (hard)", role: .destructive) {
                    // Clear the Keychain auth session too — otherwise the restored
                    // session (account + family) makes the returning-parent
                    // "welcome back" path auto-skip onboarding on the next run.
                    auth?.signOutLocally()
                    EvlinDemoShortcuts.clearFlag()
                    UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                    UserDefaults.standard.removeObject(forKey: "appMode")
                    // v2 spec §7.4: clear the v2 account/profile + family/device ids
                    // so both parent AND kid re-onboard from scratch.
                    for key in ["evlin.accountID", "evlin.parentProfileID",
                                "evlin.childProfileID", "evlin.familyID",
                                "evlin.childDeviceID", "evlin.childProfileName",
                                "evlin.childBirthYear", "evlin.childGender"] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    useV2Flow = true
                    step = .welcome
                    childName = ""
                    familyID = nil
                }
            } label: {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(Circle().fill(Color.black.opacity(0.08)))
            }
            .padding(.top, 60)
            .padding(.trailing, 12)
            #endif
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStep { step = .modeSelect }

            case .modeSelect:
                ModeSelectStep(
                    onSelect: { mode in
                        // Onboarding v2 (scaffold) is the DEFAULT next-path.
                        // Each role enters its v2 sequence (spec §7.1 / §7.2).
                        if useV2Flow {
                            switch mode {
                            case .parent:
                                appMode = "parent"
                                step = .parentSignIn
                            case .child:
                                appMode = "child"
                                step = .childProfile
                            }
                            return
                        }

                        // ---- Legacy v1 flow (kept reachable) ----
                        switch mode {
                        case .parent:
                            appMode = "parent"
                            // Pair first, then pick protection mode.
                            // Rationale: Max-mode-specific steps (Apple ID
                            // setup) need a real `familyID`, which only
                            // exists after /family/pair. Going
                            // ProtectionLevel → Pair was forcing users to
                            // commit to "max" up front, then stranding
                            // them in a flow that couldn't complete without
                            // a child Apple ID. Now: pair (with default
                            // "std" on the wire), then user picks; we PUT
                            // /family/{id}/protection-mode if they chose
                            // "max" before continuing to mode-specific steps.
                            //
                            // DEBUG insert: backendChoice step lets the dev
                            // commit to Local vs Production BEFORE pairing.
                            // family / device IDs only exist in the backend
                            // they were generated on, so picking after-the-
                            // fact (via Settings picker) silently breaks
                            // every subsequent chat call.
                            #if DEBUG
                            step = .backendChoice
                            #else
                            step = .parentPairingCode
                            #endif
                        case .child:
                            appMode = "child"
                            #if DEBUG
                            step = .backendChoice
                            #else
                            step = .childEnterPairingCode
                            #endif
                        }
                    },
                    onDemoJump: { mode in
                        EvlinDemoShortcuts.enable()
                        switch mode {
                        case .parent:
                            EvlinDemoShortcuts.seedPlaceholderChildUUIDIfMissing()
                            appMode = "parent"
                        case .child:
                            appMode = "child"
                            UserDefaults.standard.set(
                                OnboardingDemoPlaceholders.childDeviceUUIDString,
                                forKey: "evlin.childDeviceID"
                            )
                        }
                        onboardingComplete = true
                        EvlinDemoShortcuts.scheduleBackendDemoPairingIfNeeded()
                    }
                )

            // MARK: - Backend choice (DEBUG only — Release skips this case)

            case .backendChoice:
                BackendChoiceStep(onContinue: {
                    // Branch to the pairing step that matches the role the
                    // user already picked in modeSelect.
                    if appMode == "child" {
                        step = .childEnterPairingCode
                    } else {
                        step = .parentPairingCode
                    }
                })

            // MARK: - Parent flow

            case .parentAddChild:
                // Legacy case kept for enum compatibility; route straight through
                Color.clear.onAppear { step = .parentPairingCode }

            case .parentPairingCode:
                PairingCodeStep(
                    childName: $childName,
                    protectionMode: $protectionMode,
                    familyID: $familyID,
                    parentDeviceID: $parentDeviceID,
                    pairingCode: $pairingCode
                ) {
                    // v2: the 6-digit fallback rejoins the v2 chain at
                    // parentConnected. v1: pairing succeeded → parent picks
                    // protection mode (Max/Std branch inside
                    // .parentProtectionLevel, after a chance to PUT
                    // /family/{id}/protection-mode).
                    step = useV2Flow ? .parentConnected : .parentProtectionLevel
                }

            case .parentProtectionLevel:
                ProtectionLevelStep(mode: $protectionMode) {
                    // If parent picked "max" (default at pair time was "std"),
                    // push the change to the family row before continuing into
                    // Max-only steps that read protection_mode from DB. PUT is
                    // fire-and-forget — failures get logged in the helper.
                    if let fid = familyID, protectionMode == "max" {
                        Task {
                            await Self.updateFamilyProtectionMode(
                                familyID: fid,
                                mode: "max",
                                apiClient: apiClient,
                            )
                        }
                    }
                    step = protectionMode == "max"
                        ? .parentMaxWhyChildAppleID
                        : .parentStdSetPasscode
                }

            // Max path
            case .parentMaxWhyChildAppleID:
                WhyChildAppleIDStep { step = .parentMaxCreateChildAppleID }

            case .parentMaxCreateChildAppleID:
                CreateChildAppleIDStep { step = .parentMaxSignInOnChild }

            case .parentMaxSignInOnChild:
                SignInOnChildStep { step = .parentMaxWaitForAuth }

            case .parentMaxWaitForAuth:
                WaitForAuthStep(familyID: familyID ?? UUID()) {
                    step = .parentFirstSavedList
                }

            case .parentFirstSavedList:
                ParentFirstSavedListStep(
                    familyID: familyID ?? UUID(),
                    parentDeviceID: parentDeviceID ?? UUID()
                ) {
                    step = .parentDone
                }

            // Std path
            case .parentStdSetPasscode:
                SetPasscodeStep { step = .parentDone }

            case .parentDone:
                DoneStep {
                    // onboardingComplete flipped inside DoneStep; appMode already set
                }

            // MARK: - Child flow

            case .childEnterPairingCode:
                EnterPairingCodeStep(
                    familyID: $familyID,
                    childDeviceID: $childDeviceID,
                    protectionMode: $protectionMode
                ) {
                    step = .childGrantPermission
                }

            case .childGrantPermission:
                // REUSED by v2 — v2 next is childAllowNotifications, v1 is
                // childDeletionProtection.
                GrantPermissionStep(
                    childDeviceID: childDeviceID ?? OnboardingDemoPlaceholders.childDeviceUUID,
                    protectionMode: protectionMode
                ) {
                    step = useV2Flow ? .childAllowNotifications : .childDeletionProtection
                }

            case .childDeletionProtection:
                // REUSED by v2 — v2 next is childLockableHub, v1 is
                // childCategoryDefaults.
                DeletionProtectionStep {
                    step = useV2Flow ? .childLockableHub : .childCategoryDefaults
                }

            case .childCategoryDefaults:
                CategoryDefaultsStep(
                    childDeviceID: childDeviceID ?? OnboardingDemoPlaceholders.childDeviceUUID
                ) {
                    // Max-mode children skip the first-list step (parent builds lists)
                    step = protectionMode == "std" ? .childFirstSavedList : .childReady
                }

            case .childFirstSavedList:
                ChildFirstSavedListStep(
                    familyID: familyID ?? UUID(),
                    childDeviceID: childDeviceID ?? OnboardingDemoPlaceholders.childDeviceUUID
                ) {
                    step = .childReady
                }

            case .childReady:
                ChildReadyStep(
                    childDeviceID: childDeviceID,
                    familyID: familyID
                ) {
                    // onboardingComplete flipped inside ChildReadyStep; appMode already set
                }

            // MARK: - Onboarding v2 — PARENT (live backend)
            //
            // Each screen now performs its REAL action (auth / PUT /me/profile /
            // POST /family/pair) with loading + error states; next/back still
            // drive the v2 parent chain (spec §7.1): signIn → profile →
            // newOrJoin → pairScan → connected → waitingForKid → setPasscode →
            // firstActions → itWorks → done. State (session, familyID, kidName)
            // is threaded through the @State fields above.

            case .parentSignIn:
                ParentSignInStep(
                    auth: auth,
                    // Plan 8 — returning-parent recovery: if the signed-in
                    // account ALREADY has a family (needs_family == false /
                    // familyID != nil), skip the new-family chain and go
                    // straight to the recovery landing (register this device +
                    // load the family). A brand-new account (no family yet)
                    // continues into profile → new-or-join as before.
                    onSignedIn: {
                        step = parentHasExistingFamily ? .parentBackInInstantly : .parentProfile
                    },
                    onBack: { step = .modeSelect }
                )

            case .parentProfile:
                ParentProfileStep(
                    apiClient: apiClient,
                    onSaved: { step = .parentNewOrJoin },
                    onBack: { step = .parentSignIn }
                )

            case .parentNewOrJoin:
                ParentNewOrJoinStep(
                    apiClient: apiClient,
                    // "Start a new family" → pair (the kid creates the family;
                    // the parent pairs). "Join existing" (Plan 5) consumes the
                    // co-parent invite HERE and routes to the waiting-for-owner
                    // approval poll — it does NOT pair a kid.
                    onStartNew: { step = .parentPairScan },
                    onJoinCode: { code in await joinCoParentFamily(code) },
                    onBack: { step = .parentProfile }
                )

            // Plan 5 — co-parent consumed an invite and is awaiting owner
            // approval. Poll /family/me until account.family_id binds, then go
            // to the recovery landing (register device + load family). Never
            // pairs a kid.
            case .parentCoParentJoin:
                ParentCoParentJoinStep(
                    apiClient: apiClient,
                    onApproved: { step = .parentBackInInstantly },
                    onBack: { step = .parentNewOrJoin }
                )

            // Plan 8 — returning-parent recovery / approved co-parent landing.
            // Register this device + load FamilyStore, then finish onboarding.
            case .parentBackInInstantly:
                ParentBackInInstantlyStep(
                    apiClient: apiClient,
                    recover: { await recoverExistingFamily() },
                    onDone: { finishParentOnboarding() },
                    onBack: { step = .parentNewOrJoin }
                )

            case .parentPairScan:
                ParentPairScanStep(
                    // Scan is a placeholder; the typed-code path is the real
                    // one. Both submit POST /family/pair via onPaired(code:).
                    onPaired: { code in await pairWithKidCode(code) },
                    pairedSucceeded: pairedChildDeviceID != nil,
                    onAdvance: { step = .parentConnected },
                    onEnterCodeInstead: { step = .parentPairingCode },
                    onBack: { step = .parentNewOrJoin }
                )

            case .parentConnected:
                ParentConnectedStep(
                    kidName: kidName,
                    // P3: a REAL wait — poll the kid's onboarding readiness
                    // (Screen Time + a lockable app) before the first block.
                    // (I5: the Screen Time passcode moved to the kid chain.)
                    onContinue: { step = .parentWaitingForKid },
                    onBack: { step = .parentPairScan }
                )

            case .parentWaitingForKid:
                ParentWaitingForKidStep(
                    apiClient: apiClient,
                    childDeviceID: pairedChildDeviceID ?? childDeviceID,
                    kidName: kidName,
                    onReady: { r in
                        firstBlockApp = r.first_block_app
                        step = .parentFirstActions
                    },
                    onBack: { step = .parentConnected }
                )

            case .parentSetPasscode:
                ParentSetPasscodeV2Step(
                    onContinue: { step = .parentFirstActions },
                    onBack: { step = .parentWaitingForKid }
                )

            case .parentFirstActions:
                // Plan 7 — the live first-actions test. Threads the real child
                // DEVICE id + familyID + kid name so the "Send block" button
                // fires a real lock and polls for the honest lock-applied ack.
                ParentFirstActionsStep(
                    apiClient: apiClient,
                    familyID: familyID,
                    childDeviceID: pairedChildDeviceID ?? childDeviceID,
                    kidName: kidName,
                    firstBlockApp: firstBlockApp,
                    onContinue: { step = .parentItWorks },
                    onBack: { step = .parentConnected }
                )

            case .parentItWorks:
                ParentItWorksStep(
                    onContinue: { step = .parentTryReflection },
                    onBack: { step = .parentFirstActions }
                )

            case .parentTryReflection:
                ParentTryReflectionStep(
                    apiClient: apiClient,
                    childDeviceID: pairedChildDeviceID ?? childDeviceID,
                    kidName: kidName,
                    onContinue: { step = .parentDone },
                    onBack: { step = .parentItWorks }
                )

            // MARK: - Onboarding v2 (scaffold) — KID
            //
            // Tappable placeholders only. next/back drive the v2 kid chain
            // (spec §7.2): childProfile → childShowCode → childConnected
            // → childConsentDisclosure → childGrantPermission (reused)
            // → childAllowNotifications → childDeletionProtection (reused)
            // → childLockableHub → childReady (reused).

            case .childProfile:
                ChildProfileStep(
                    // Capture the kid's profile LOCALLY; the family doesn't exist
                    // yet (created on the next screen). Threaded forward + persisted.
                    name: $childProfileName,
                    birthYear: $childBirthYear,
                    gender: $childGender,
                    onContinue: { step = .childShowCode },
                    onBack: { step = .modeSelect }
                )

            case .childShowCode:
                ChildShowCodeStep(
                    // On appear: POST /family/create → real 6-digit code +
                    // child_device_id, threaded into state. Returns nil on
                    // success or an error string for inline display.
                    createFamily: { await createKidFamily() },
                    pairingCode: childPairingCode,
                    onConnected: { step = .childConnected },
                    onBack: { step = .childProfile }
                )

            case .childConnected:
                ChildConnectedStep(
                    onContinue: { step = .childConsentDisclosure },
                    onBack: { step = .childShowCode }
                )

            case .childConsentDisclosure:
                ChildConsentDisclosureStep(
                    onContinue: { step = .childGrantPermission },
                    onBack: { step = .childConnected }
                )

            case .childAllowNotifications:
                ChildAllowNotificationsStep(
                    onContinue: { step = .childDeletionProtection },
                    onBack: { step = .childGrantPermission }
                )

            case .childLockableHub:
                ChildLockableHubStep(
                    childDeviceID: childDeviceID,
                    onContinue: { step = .childReady },
                    onBack: { step = .childDeletionProtection }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    /// Submits the kid's 6-digit code to POST /family/pair (authed), threads the
    /// bound familyID + kid name into the coordinator state, persists the same
    /// UserDefaults keys the rest of the app reads (mirroring legacy
    /// PairingCodeStep), and loads the FamilyStore so the connected screen +
    /// Home see the freshly-bound family. Returns `nil` on success or a
    /// human-readable error string on a 4xx/network failure (the calling screen
    /// renders it inline). Advancing to parentConnected is the caller's job
    /// (it observes `pairedChildDeviceID != nil`).
    @MainActor
    private func pairWithKidCode(_ code: String) async -> String? {
        let trimmed = code.filter(\.isNumber)
        guard trimmed.count == 6 else { return "Enter the 6-digit code." }
        do {
            let r = try await apiClient.pairFamily(
                code: trimmed,
                deviceLabel: UIDevice.current.name
            )
            // Thread state.
            familyID = r.family_id
            parentDeviceID = r.parent_device_id
            pairedChildDeviceID = r.child_device_id
            childDeviceID = r.child_device_id
            pairingCode = trimmed
            protectionMode = r.protection_mode

            // Persist the same keys the rest of the app reads (chat queueing,
            // BigKid panel, poller) — identical to legacy PairingCodeStep.
            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.parent_device_id.uuidString, forKey: "evlin.parentDeviceID")
            UserDefaults.standard.set(r.child_device_id.uuidString, forKey: "evlin.childDeviceID")

            // Refresh the family aggregate, then resolve the kid's display name
            // for the connected screen. The pair response carries only ids, so
            // the name comes from GET /me/profile (FamilyStore) — the child the
            // consumed code belonged to. Fall back to "your kid" if the device
            // isn't yet projected (e.g. before the kid finishes their profile).
            await familyStore.load()
            kidName = resolvedKidName(forChildDeviceID: r.child_device_id)
            return nil
        } catch let APIError.serverError(status) {
            switch status {
            case 404: return "That code wasn't found. Double-check the 6 digits."
            case 400: return "That code has expired or was already used. Ask your kid for a fresh one."
            case 409: return "This account is already in a different family."
            default:  return "Couldn't pair (error \(status)). Try again."
            }
        } catch {
            return "Network error. Check your connection and try again."
        }
    }

    /// KID side: mints the family via POST /family/create, threads the bound
    /// familyID + child_device_id + 6-digit pairing code into coordinator state,
    /// and persists the same UserDefaults keys the post-onboarding kid shell
    /// reads (`evlin.familyID` / `evlin.childDeviceID`) — identical to the legacy
    /// EnterPairingCodeStep success path. The locally-captured kid profile
    /// (name / birth-year / gender) is stashed too so the post-onboarding shell
    /// (and any later parent-side child write) can recover it. Returns `nil` on
    /// success or a human-readable error string for inline display. Idempotent
    /// on the caller side: if a code is already threaded it short-circuits so a
    /// re-appear (e.g. SwiftUI re-render) doesn't mint a second family.
    @MainActor
    private func createKidFamily() async -> String? {
        if !childPairingCode.isEmpty { return nil }
        do {
            let trimmedName = childProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = try await apiClient.createFamily(
                childDeviceLabel: UIDevice.current.name,
                protectionMode: protectionMode,
                // F6: persist the kid-entered profile so the parent's Home shows
                // the real child after pairing (was stashed to UserDefaults only).
                childDisplayName: trimmedName.isEmpty ? nil : trimmedName,
                childBirthYear: childBirthYear,
                childGender: childGender
            )
            familyID = r.family_id
            childDeviceID = r.child_device_id
            childPairingCode = r.pairing_code

            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.child_device_id.uuidString, forKey: "evlin.childDeviceID")

            // Stash the locally-captured profile so the post-onboarding kid shell
            // can recover it (the parent owns the authoritative child write once
            // paired). Trimmed name only; birth-year/gender when supplied.
            if !trimmedName.isEmpty {
                childName = trimmedName
                UserDefaults.standard.set(trimmedName, forKey: "evlin.childProfileName")
            }
            if let by = childBirthYear {
                UserDefaults.standard.set(by, forKey: "evlin.childBirthYear")
            }
            if let g = childGender {
                UserDefaults.standard.set(g, forKey: "evlin.childGender")
            }
            return nil
        } catch let APIError.serverError(status) {
            return "Couldn't create your family (error \(status)). Tap Retry."
        } catch {
            return "Network error. Check your connection and tap Retry."
        }
    }

    /// Plan 5 — the co-parent join path. POSTs the entered invite code to
    /// /family/invite/consume (authed) and routes on the result. With owner-
    /// approval ON the backend returns `pending_approval` and does NOT bind
    /// account.family_id — so we advance to the waiting-for-owner poll
    /// (`parentCoParentJoin`), which finishes via `parentBackInInstantly`. If a
    /// future approval-OFF build returns `joined`, we go straight to recovery.
    /// Returns `nil` on a clean handoff or a human-readable error to show inline.
    /// This NEVER pairs a kid (a co-parent joins the existing family).
    @MainActor
    private func joinCoParentFamily(_ code: String) async -> String? {
        coParentInviteCode = code
        do {
            let result = try await apiClient.consumeCoParentInvite(code: code)
            if result.status == "pending_approval" {
                familyID = result.family_id   // not yet bound on the account, but useful
                step = .parentCoParentJoin
            } else {
                // approval OFF fallback — already bound; recover immediately.
                familyID = result.family_id
                step = .parentBackInInstantly
            }
            return nil
        } catch let APIError.serverError(status) {
            switch status {
            case 404: return "That invite code isn't valid or has expired. Check it and try again."
            case 409: return "This account already belongs to a family."
            case 429: return "Too many attempts. Try again in a minute."
            default:  return "Couldn't join (error \(status)). Try again."
            }
        } catch {
            return "Network error. Check your connection and try again."
        }
    }

    /// Plan 8 — returning-parent / approved-co-parent recovery. Registers THIS
    /// device as a parent device on the already-existing family via
    /// POST /family/device/register (authed, idempotent on X-Device-Id), loads
    /// the FamilyStore, persists the same UserDefaults keys the rest of the app
    /// reads, and resolves a family display name for the welcome-back copy.
    /// Returns the family name (or nil). Does NOT create a new family or pair a kid.
    @MainActor
    private func recoverExistingFamily() async -> String? {
        // Register this device against the bound family (idempotent upsert).
        let registered = await registerParentDevice()
        if let r = registered {
            familyID = r.family_id
            parentDeviceID = r.device_id
            UserDefaults.standard.set(r.family_id.uuidString, forKey: "evlin.familyID")
            UserDefaults.standard.set(r.device_id.uuidString, forKey: "evlin.parentDeviceID")
        } else if let fid = auth?.account?.familyID {
            // Device-register failed (e.g. transient) — still persist the family
            // id from the session so Home can load.
            familyID = fid
            UserDefaults.standard.set(fid.uuidString, forKey: "evlin.familyID")
        }
        appMode = "parent"

        // Load the family aggregate so Home renders immediately.
        await familyStore.load()
        return familyStore.family?.display_name
    }

    /// POST /family/device/register (authed) — register this device as a parent
    /// device on the account's bound family. Returns the response on success,
    /// nil on any failure (recovery degrades gracefully).
    @MainActor
    private func registerParentDevice() async -> DeviceRegisterResponseDTO? {
        try? await apiClient.registerParentDevice(
            deviceID: Self.persistentDeviceID(),
            label: UIDevice.current.name
        )
    }

    /// A stable per-install device id for X-Device-Id (so device-register is a
    /// true idempotent upsert across launches). Reuses any previously-persisted
    /// parent device id, else mints + persists a fresh UUID.
    private static func persistentDeviceID() -> UUID {
        let key = "evlin.parentDeviceID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) {
            return id
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }

    /// Finish the parent onboarding flow (recovery / co-parent landing path).
    /// Mirrors what `DoneStep` does internally for the new-family path.
    @MainActor
    private func finishParentOnboarding() {
        appMode = "parent"
        onboardingComplete = true
    }

    /// Best-effort kid display name from the loaded FamilyStore: the child whose
    /// device matches the paired `childDeviceID`, else the first child, else a
    /// neutral fallback.
    @MainActor
    private func resolvedKidName(forChildDeviceID childDeviceID: UUID) -> String {
        let idString = childDeviceID.uuidString
        if let match = familyStore.children.first(where: { child in
            child.devices.contains { $0.device_id.caseInsensitiveCompare(idString) == .orderedSame }
        }) {
            return match.display_name
        }
        return familyStore.children.first?.display_name ?? "your kid"
    }

    /// Sends a one-shot PUT `/family/{id}/protection-mode` after the parent
    /// changes the family's mode mid-onboarding (from the post-pair
    /// ProtectionLevelStep). Fire-and-forget: a network blip here is
    /// acceptable — the parent can re-pick from Settings later, and the
    /// downstream Max-flow steps don't actually read the mode back over the
    /// wire (they branch on the local `protectionMode` binding). Errors are
    /// logged in DEBUG so dev catches accidental endpoint regressions.
    private static func updateFamilyProtectionMode(
        familyID: UUID,
        mode: String,
        apiClient: APIClient,
    ) async {
        let base = apiClient.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              let url = URL(string: "\(base)/family/\(familyID.uuidString)/protection-mode")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": mode])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                #if DEBUG
                print("[OnboardingCoordinator] protection-mode PUT non-200: \(http.statusCode)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[OnboardingCoordinator] protection-mode PUT failed: \(error)")
            #endif
        }
    }
}
