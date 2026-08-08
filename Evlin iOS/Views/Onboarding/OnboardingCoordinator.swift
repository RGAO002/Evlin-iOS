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
    case parentBetaAgreement     // Beta Participation Agreement — scroll-to-bottom read gate
    case parentNewOrJoin         // mockup 5: "New family — or join an existing one"
    case parentCoParentJoin      // Plan 5: co-parent "waiting for owner approval" poll
    case parentBackInInstantly   // Plan 8: returning-parent / approved-co-parent recovery
    /// Pairing v2, parent side: the parent SHOWS a code and the kid device
    /// scans it. Replaced `parentPairScan`, whose direction only worked because
    /// the kid minted the family first — the thing v2 exists to stop.
    case parentInviteV2
    case parentConnected         // mockup 7: "Connected" (parent side)
    case parentWaitingForKid     // polls /family/pairing-status kid_onboarding_phase
    case parentSetPasscode       // mockup 14: "Lock the Screen Time settings"
    case parentFirstActions      // mockup 15: "Send your first block (test)"
    case parentItWorks           // mockup 16: "It works — the test pays off"
    case parentTryReflection     // P2: separate reflection demo (auto-clears at setup end)
    case parentSetParentPIN      // Final: claim the kid-device Parent Controls PIN (critical)

    // v2 Kid flow (new cases)
    /// Pairing v2: the kid device scans the PARENT's code, and the backend
    /// decides whether this hardware is restoring an identity it already had,
    /// joining an existing child as another device, or is genuinely new. Only
    /// the last of those asks for a name, which is why this replaces
    /// `childProfile` + `childShowCode`, both now gone.
    case childJoinV2
    case childConnected          // mockup 7 (kid): "You're linked to your parent"
    case childConsentDisclosure  // mockup 8: "What Evlin can see"
    case childAllowNotifications // mockup 10: "Allow notifications"
    case childLockableHub        // mockup 12: "Choose what Evlin can lock"
    case childSafetyLock         // mockup 14 (MOVED to kid): set the Screen Time passcode ON the kid's phone
    case childFinalSetup         // tracking selection + Evlin Parent PIN
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
    /// P5: did the kid's phone CONFIRM the first block applied? Set only when
    /// parentFirstActions advances into the receipt/payoff screen.
    @State private var firstBlockLanded = false
    /// True when the parent explicitly skipped the first-block demo. In that
    /// path we go straight to Reflection, and Back should return to first block
    /// instead of showing the skipped receipt screen.
    @State private var skippedFirstBlock = false

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
    /// Pairing v2 parent side. Held here rather than inside the step so the
    /// invite (and its polling) survives a SwiftUI re-render — re-minting on
    /// every redraw would invalidate the code the kid is currently looking at.
    @StateObject private var parentInviteModel = ParentInviteModel()
    /// Single-device demo only: the code the parent half minted, fed to the kid
    /// half so the tester doesn't retype what is already on screen.
    @State private var singleDeviceInviteCode: String? = nil

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
    @State private var childAvatar: UIImage? = nil   // uploaded after /family/create
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

    /// True only AFTER the tester picks "Single Device Mode" (set in `startSingleDeviceFlow`).
    /// Deliberately NOT derived from the persisted `EvlinDemoShortcuts` flag — that flag survives
    /// across runs to drive the home-screen float, so reading it here would light up the role pill
    /// + interleave before the card is even tapped. Drives the role pill + every interleave branch.
    @State private var singleDevice = false
    @State private var sdDiag = ""   // temp on-screen debug for the single-device flow

    /// Single Device Mode top banner — tells the tester which role this phone is currently
    /// playing (the P/K float only appears AFTER onboarding finishes, so during the interleave
    /// this is the only role indicator).
    @ViewBuilder private var singleDeviceBanner: some View {
        let isKid = appMode == "child"
        HStack(spacing: 4) {
            Image(systemName: isKid ? "figure.child" : "person.fill")
                .font(.system(size: 10, weight: .bold))
            Text("\(isKid ? "KID" : "PARENT") · \(String(describing: step))\(sdDiag.isEmpty ? "" : " · \(sdDiag)")")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isKid
                ? Color(red: 0xA6/255, green: 0x44/255, blue: 0x3E/255)   // kid = brick red
                : Color(red: 0x04/255, green: 0x16/255, blue: 0x27/255))  // parent = navy
        )
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .allowsHitTesting(false)
    }

    /// Entry from the ModeSelect "Single Device Mode" card: enable the flag + start the real v2
    /// kid chain. The interleave (kid create → parent pair → kid permit → parent payoff) is
    /// driven by `singleDevice` branches at each boundary below — no new screens.
    private func startSingleDeviceFlow() {
        // Fresh demo identity each run: signs out any prior session + mints a NEW
        // email/password/install id, so we never reuse a stale (e.g. old bad-domain) demo email
        // and /family/pair never 409s on a recycled parent account.
        SingleDeviceSession.shared.resetForNewRun(auth: auth)
        singleDevice = true
        SingleDeviceSession.shared.enable()
        useV2Flow = true
        kidName = ""
        // Pairing v2 inverts the order: the family is born on the parent
        // account, so the parent half runs FIRST and mints the code the kid
        // half of this same phone will consume.
        SingleDeviceSession.shared.stage = .parentPair
        Task { @MainActor in
            await auth?.signInDemoAccount()
            appMode = "parent"
            step = .parentProfile
        }
    }

    /// Single device: the parent half just minted a code, so hand it to the kid
    /// half instead of asking the tester to retype what is on screen. The join
    /// itself goes through the same resolve/commit path a real kid device uses.
    private func singleDeviceJoinAsKid(code: String) {
        SingleDeviceSession.shared.stage = .kidPermit
        singleDeviceInviteCode = code
        appMode = "child"
        step = .childJoinV2
    }

    /// Kid finished creating the family + code → switch THIS device to the parent side, sign in
    /// the per-run demo account (fresh each run so /family/pair never 409s), then collect the
    /// parent profile. (Async sign-in runs while the code screen is still up; brief.)
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
                    // Single Device Mode drives its own parent→kid handoff now
                    // (the parent half mints the code); ignore this legacy jump
                    // so the two mechanisms don't race.
                    guard !SingleDeviceSession.shared.isEnabled else { return }
                    appMode = "parent"
                    // v2 sends the parent to the invite screen (they SHOW a
                    // code); v1 lands on the code-entry step.
                    step = useV2Flow ? .parentInviteV2 : .parentPairingCode
                }
                #endif
                // Single-device role tag: a small centered pill in a thin top inset. Inset (not
                // overlay) so it never covers the screen's own title/text; compact pill (not a
                // full-width bar) so it barely takes any height.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if singleDevice {
                        singleDeviceBanner
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                            .padding(.bottom, 2)
                    }
                }

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
                    step = .childJoinV2
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
                    // Clear the kid create-state too, otherwise createKidFamily's
                    // "already minted" short-circuit skips the re-create and the
                    // new name never upserts (kid keeps showing the old name).
                    childProfileName = ""
                    childPairingCode = ""
                    childDeviceID = nil
                    firstBlockApp = nil
                    firstBlockLanded = false
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
                        // Picking a REAL parent/kid setup → this is not single-device. Drop any
                        // leftover single-device flag from a prior demo run so the home-screen
                        // float doesn't leak into a normal device.
                        singleDevice = false
                        EvlinDemoShortcuts.clearFlag()
                        // Onboarding v2 (scaffold) is the DEFAULT next-path.
                        // Each role enters its v2 sequence (spec §7.1 / §7.2).
                        if useV2Flow {
                            switch mode {
                            case .parent:
                                appMode = "parent"
                                step = .parentSignIn
                            case .child:
                                appMode = "child"
                                // Pairing v2: scan first, ask for a name only if
                                // the backend says this is a genuinely new child.
                                step = .childJoinV2
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
                    onSingleDevice: { startSingleDeviceFlow() }
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
                // REUSED by v2 as the single "grant access" checklist. v2
                // now keeps Screen Time, notifications, and deletion
                // protection on one page, then moves straight to lockable
                // target capture. Legacy still keeps its separate deletion
                // step.
                //
                // KID-4: the demo placeholder UUID fallback is DEBUG-only.
                // In Release a nil childDeviceID means family create/pair never
                // completed — never grant permissions against a fake device id;
                // render an inline error with a way back instead.
                if let grantChildDeviceID = grantPermissionChildDeviceID {
                    GrantPermissionStep(
                        childDeviceID: grantChildDeviceID,
                        protectionMode: protectionMode
                    ) {
                        step = useV2Flow ? .childLockableHub : .childDeletionProtection
                    }
                } else {
                    missingChildDeviceFallback
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
                    familyID: familyID,
                    onEnter: {
                        // onboardingComplete flipped inside ChildReadyStep; appMode already set
                    },
                    // Single device: the kid finished the REAL setup (Screen Time grant + picked
                    // apps) on THIS phone, so we're done. Skip the parent payoff tail
                    // (waiting/passcode/first-block) — it relies on a cross-device readiness poll
                    // that just spins on one phone — and drop straight into the parent app. The
                    // P/K ball + chat let the tester send a real lock from here.
                    onSingleDeviceContinue: singleDevice ? {
                        SingleDeviceSession.shared.stage = .done
                        appMode = "parent"
                        onboardingComplete = true
                    } : nil
                )

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
                    onSaved: { step = .parentBetaAgreement },
                    onBack: { step = .parentSignIn }
                )

            case .parentBetaAgreement:
                // Beta Participation Agreement read gate — sits between account
                // profile and family enrollment so BOTH the new-family owner and
                // a joining co-parent pass through it, before any child is enrolled.
                ParentBetaAgreementStep(
                    // Single device always starts a new family (the kid created it) → skip the
                    // new-or-join chooser and go straight to pairing.
                    // Single device: pair programmatically with the known code (no scan screen).
                    onContinue: {
                        // Record the read ack (best-effort — if it doesn't land,
                        // the parent-root launch gate re-prompts on first open).
                        Task {
                            try? await apiClient.postAgreementAck(
                                version: BetaAgreementContent.wireVersion)
                        }
                        // Single device skips "new or join": there is only ever
                        // one family, and the next thing needed is the code.
                        if singleDevice {
                            parentInviteModel.api = .live(client: apiClient)
                            parentInviteModel.onCodeReady = { invite in
                                singleDeviceJoinAsKid(code: invite.codeDisplay)
                            }
                            step = .parentInviteV2
                        } else {
                            step = .parentNewOrJoin
                        }
                    },
                    onBack: { step = .parentProfile }
                )

            case .parentNewOrJoin:
                ParentNewOrJoinStep(
                    apiClient: apiClient,
                    // "Start a new family" → pairing v2: the family is created
                    // on THIS account and the parent shows a code for the kid
                    // device to scan. "Join existing" (Plan 5) consumes the
                    // co-parent invite HERE and routes to the waiting-for-owner
                    // approval poll — it does NOT pair a kid.
                    onStartNew: {
                        // Configure before the step exists: it mints on
                        // appear, so injecting from the step's own onAppear
                        // would race its .task.
                        parentInviteModel.api = .live(client: apiClient)
                        parentInviteModel.onJoined = { identity in
                            AppControlsIdentityGuard.adopt(
                                childDeviceID: identity.childDeviceID
                            )
                            familyID = identity.familyID
                            pairedChildDeviceID = identity.childDeviceID
                            childDeviceID = identity.childDeviceID
                            UserDefaults.standard.set(
                                identity.familyID.uuidString,
                                forKey: "evlin.familyID"
                            )
                            UserDefaults.standard.set(
                                identity.childDeviceID.uuidString,
                                forKey: "evlin.childDeviceID"
                            )
                            step = .parentConnected
                        }
                        step = .parentInviteV2
                    },
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

            case .parentInviteV2:
                ParentInviteStep(
                    model: parentInviteModel,
                    // First device for a brand-new family, so there is no child
                    // to target yet; the kid device supplies the name.
                    purpose: .newChild,
                    targetChildProfileID: nil,
                    targetChildName: nil
                )

            case .parentConnected:
                ParentConnectedStep(
                    kidName: kidName,
                    // P3: a REAL wait — poll the kid's onboarding readiness
                    // (Screen Time + a lockable app) before the first block.
                    // (I5: the Screen Time passcode moved to the kid chain.)
                    onContinue: {
                        // Single device: parent paired → become the kid to grant + pick apps.
                        if singleDevice {
                            SingleDeviceSession.shared.stage = .kidPermit
                            appMode = "child"
                            step = .childConnected
                        } else {
                            step = .parentWaitingForKid
                        }
                    },
                    onBack: { step = .parentInviteV2 }
                )

            case .parentWaitingForKid:
                if singleDevice {
                    // Single device: the kid already did the REAL setup on THIS phone, so the
                    // cross-device readiness poll just spins here forever. Don't wait — finish
                    // onboarding and drop into the parent app (P/K ball + chat send a real lock
                    // from there). Safety net: no single-device path should reach this screen
                    // (childReady now completes onboarding directly), but if one does, never hang.
                    Color.evSurface
                        .ignoresSafeArea()
                        .onAppear {
                            SingleDeviceSession.shared.stage = .done
                            appMode = "parent"
                            onboardingComplete = true
                        }
                } else {
                    ParentWaitingForKidStep(
                        apiClient: apiClient,
                        childDeviceID: pairedChildDeviceID ?? childDeviceID,
                        kidName: kidName,
                        onReady: { r in
                            // The kid's safety lock (Screen Time passcode) moved to the KID
                            // chain, so the parent no longer sets a passcode here — once the kid
                            // signals "All set" the parent goes straight to the first-block test.
                            firstBlockApp = r.first_block_app
                            step = .parentFirstActions
                        },
                        onBack: { step = .parentConnected }
                    )
                }

            case .parentSetPasscode:
                ParentSetPasscodeV2Step(
                    kidName: kidName,
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
                    // P5: thread whether the kid's phone confirmed the lock
                    // before showing the receipt/payoff screen.
                    onContinue: { landed in
                        firstBlockLanded = landed
                        skippedFirstBlock = false
                        step = .parentItWorks
                    },
                    onSkip: {
                        firstBlockLanded = false
                        skippedFirstBlock = true
                        switch FirstActionsLogic.routeAfterFirstBlockSkip() {
                        case .receiptPayoff:
                            step = .parentItWorks
                        case .tryReflection:
                            step = .parentTryReflection
                        }
                    },
                    onBack: { step = .parentWaitingForKid },
                    singleDevice: singleDevice
                )

            case .parentItWorks:
                ParentItWorksStep(
                    apiClient: apiClient,
                    familyID: familyID,
                    childDeviceID: pairedChildDeviceID ?? childDeviceID,
                    kidName: kidName,
                    blockAppName: firstBlockApp?.display_name ?? "the app",
                    firstBlockApp: firstBlockApp,
                    landed: firstBlockLanded,
                    onContinue: { step = .parentTryReflection },
                    onBack: { step = .parentFirstActions }
                )

            case .parentTryReflection:
                ParentTryReflectionStep(
                    apiClient: apiClient,
                    childDeviceID: pairedChildDeviceID ?? childDeviceID,
                    kidName: kidName,
                    onContinue: { step = .parentSetParentPIN },
                    onBack: { step = skippedFirstBlock ? .parentFirstActions : .parentItWorks }
                )

            case .parentSetParentPIN:
                ParentSetParentPINStep(
                    kidName: kidName,
                    singleDevice: singleDevice,
                    onContinue: { step = .parentDone },
                    onBack: { step = .parentTryReflection }
                )

            // MARK: - Onboarding v2 (scaffold) — KID
            //
            // Tappable placeholders only. next/back drive the v2 kid chain
            // (spec §7.2): childProfile → childShowCode → childConnected
            // → childConsentDisclosure → childGrantPermission (reused)
            // → childAllowNotifications → childDeletionProtection (reused)
            // → childLockableHub → childReady (reused).

            case .childJoinV2:
                KidJoinFlowView(
                    client: PairingV2Client.production() ?? PairingV2Client(
                        baseURL: URL(string: APIClient.currentBaseURL)!
                    ),
                    store: PendingAdoptionStore.shared()
                        ?? PendingAdoptionStore(
                            directoryURL: FileManager.default.temporaryDirectory
                        ),
                    deviceSnapshot: kidJoinDeviceSnapshot(),
                    // Non-nil when this hardware already carries a child
                    // identity; the backend uses it to offer a restore, and the
                    // adoption executor uses it to decide whether the old
                    // identity has to be torn down first.
                    currentOwnerUUID: UUID(
                        uuidString: UserDefaults.standard
                            .string(forKey: DeviceIdentity.childKey) ?? ""
                    ),
                    autoInvite: singleDeviceInviteCode.map { .legacySixDigit($0) },
                    onJoined: { result in
                        adoptKidJoinResult(result)
                        startKidJoinMeteringBootstrap(for: result.childDeviceID)
                        singleDeviceInviteCode = nil
                        step = .childConnected
                    },
                    // Single device has no mode screen to fall back to — the
                    // parent half of this phone owns the family already.
                    onBack: { step = singleDevice ? .parentInviteV2 : .modeSelect }
                )

            case .childConnected:
                ChildConnectedStep(
                    onContinue: { step = .childConsentDisclosure },
                    onBack: { step = .childJoinV2 }
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
                    familyID: familyID,
                    childDeviceID: childDeviceID,
                    onContinue: { step = .childSafetyLock },
                    onBack: { step = .childGrantPermission }
                )

            case .childSafetyLock:
                // MOVED from the parent chain: the Screen Time passcode is set ON the
                // kid's phone (it's what stops the kid disabling Evlin), so it's the
                // safety step before final tracking and PIN setup. Reuses the
                // passcode screen with kid theming/copy.
                ParentSetPasscodeV2Step(
                    kidName: kidName,
                    onContinue: { step = .childFinalSetup },
                    onBack: { step = .childLockableHub },
                    role: .child,
                    phase: "5 · Safety",
                    stepIndex: 10,
                    dotsCurrent: 9,
                    total: 11   // childTotal (private to ChildV2PlaceholderSteps.swift)
                )

            case .childFinalSetup:
                ChildFinalSetupStep(
                    childDeviceID: childDeviceID,
                    familyID: familyID,
                    kidName: kidName,
                    onEnter: {},
                    onSingleDeviceContinue: singleDevice ? {
                        SingleDeviceSession.shared.stage = .done
                        appMode = "parent"
                        onboardingComplete = true
                    } : nil,
                    onBack: { step = .childSafetyLock }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    /// KID-4: the child device id fed to GrantPermissionStep. The demo
    /// placeholder UUID is a DEBUG convenience only (single-device tap-through);
    /// Release returns nil when no real device id exists so the coordinator can
    /// show an inline error instead of granting against a fake UUID.
    private var grantPermissionChildDeviceID: UUID? {
        #if DEBUG
        return childDeviceID ?? OnboardingDemoPlaceholders.childDeviceUUID
        #else
        return childDeviceID
        #endif
    }

    /// KID-4 (Release-reachable): rendered when childGrantPermission is hit
    /// without a real child device id. Explains the broken state and routes the
    /// kid back to re-establish the device instead of faking a grant.
    private var missingChildDeviceFallback: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Text("Something went wrong")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)
                .multilineTextAlignment(.center)
            Text("This phone isn't registered with a family yet, so permissions can't be granted. Go back and pair again.")
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Spacer()
            Button {
                step = useV2Flow ? .childJoinV2 : .childEnterPairingCode
            } label: {
                Text("Go back")
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
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    @MainActor
    private func recordPairDiagnostic(_ message: String) {
        UserDefaults.standard.set(message, forKey: "evlin.onboardingPairDiag")
        #if DEBUG
        print("[OnboardingPair] \(message)")
        #endif
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
                childGender: childGender,
                resetChildAvatar: childAvatar == nil,
                // Single device: fresh install id per run → a brand-new family each demo
                // (not the idempotent one) so a reset+rerun never reuses a stale child row.
                clientInstallIDOverride: singleDevice ? SingleDeviceSession.shared.clientInstallIDOverride : nil
            )
            familyID = r.family_id
            AppControlsIdentityGuard.adopt(childDeviceID: r.child_device_id)
            childDeviceID = r.child_device_id
            childPairingCode = r.pairing_code

            // Upload the kid's picked avatar photo now that we have the device id
            // (best-effort; the initials fallback covers a failure).
            if let img = childAvatar, let data = evlinAvatarJPEG(img) {
                try? await apiClient.uploadChildAvatar(childDeviceID: r.child_device_id, jpegData: data)
            }

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

    // MARK: - Pairing v2 (kid side)

    /// What the backend matches this hardware against. The keychain UUID is the
    /// primary key for "we have seen this device"; install_id is the fallback
    /// for a reinstall that lost it. Both are scoped to the inviting family
    /// server-side, so a device that belonged to another family gets a fresh
    /// identity rather than being handed the old one.
    private func kidJoinDeviceSnapshot() -> [String: String] {
        // Same source the legacy register/pair seams use, so a device joining
        // through v2 lands in the parent's list looking like every other one —
        // omitting the model left a row showing nothing but "26.5.2".
        let info = DeviceInfoProvider.current()
        var snapshot: [String: String] = [
            "install_id": APIClient.clientInstallID,
            "platform": info.platform,
            "os_version": info.os_version,
            "device_model": info.device_model,
            "device_model_id": info.device_model_id,
            "device_name": UIDevice.current.name,
        ]
        // UserDefaults dies with an app deletion — reading only it meant a
        // reinstalled device joined with NO identity and the backend could
        // never offer restore (resolution 2026-08-05 21:48: keychain field
        // empty, restore withheld). The Keychain mirror is the copy that
        // survives; fall back to it exactly as its name promises.
        if let existing = UserDefaults.standard.string(forKey: DeviceIdentity.childKey)
            ?? DeviceIdentity.shared.mirroredValue(forKey: DeviceIdentity.childKey) {
            snapshot["keychain_device_uuid"] = existing
        }
        return snapshot
    }

    /// Persist the join's identity immediately. A completed pairing must
    /// survive process termination even while its retained App Controls
    /// selection is still being re-published under the new device row.
    private func adoptKidJoinResult(_ result: PairingCommitResult) {
        ParentPINSyncCoordinator.prepareForAdoption(
            deviceID: result.childDeviceID
        )
        // The retained App Controls selection is only meaningful if it was
        // captured under THIS child-device identity; otherwise its tokens are
        // from a previous life and arm monitors that never fire.
        AppControlsIdentityGuard.adopt(childDeviceID: result.childDeviceID)
        familyID = result.familyID
        childDeviceID = result.childDeviceID
        UserDefaults.standard.set(result.familyID.uuidString, forKey: "evlin.familyID")
        UserDefaults.standard.set(result.childDeviceID.uuidString,
                                  forKey: DeviceIdentity.childKey)
        UserDefaults.standard.set(result.childProfileID.uuidString,
                                  forKey: "evlin.childProfileID")
        DeviceIdentity.shared.capture()
    }

    /// Pairing creates a new backend device identity while preserving this
    /// hardware's local App Controls selection. Make that selection useful
    /// immediately: mirror the new metering owner, publish the retained blob
    /// under the new device ID, then fetch the policy that may already be at
    /// zero. This deliberately runs before the user advances beyond the
    /// connected screen, rather than waiting for the normal K-home poll loop.
    @MainActor
    private func startKidJoinMeteringBootstrap(for childDeviceID: UUID) {
        let appGroupDefaults = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        )
        let bootstrap = KidJoinMeteringBootstrap(
            prepareIdentity: { deviceID in
                EarnedBudgetArming.mirrorChildIdentity(
                    deviceID,
                    appGroupDefaults: appGroupDefaults,
                    epochStore: .shared
                )
                appGroupDefaults?.set(
                    APIClient.currentBaseURL,
                    forKey: MeteringProductionComposition.baseURLKey
                )
            },
            convergeAppLimitIdentity: { deviceID in
                AppLimitPairingIdentityConvergence.run(
                    ownerChildDeviceID: deviceID
                )
            },
            publishSelection: {
                await AppControlsBackendSync.publishDefaultLockGroupIfNeeded(
                    for: childDeviceID
                )
            },
            publishMatchedCatalog: {
                await AppControlsBackendSync.republishMatchedCatalogIfNeeded(
                    for: childDeviceID,
                    forceSnapshot: true
                )
            },
            recoverMetering: { [apiClient] in
                guard let baseURL = URL(string: apiClient.baseURL) else {
                    MeteringFlightRecorder.emitFailure(
                        site: "pairing.metering_bootstrap",
                        verdict: "invalid_base_url"
                    )
                    return
                }
                do {
                    let state = try await BigKidAPIClient(
                        baseURL: baseURL,
                        childId: childDeviceID
                    ).fetchState()
                    try await MeteringProductionComposition.recoverFromSharedConfiguration(
                        role: .app,
                        runtime: state.earnedTimeRuntime,
                        usageCountingAllowed: state.effectiveUsageCountingAllowed
                    )
                } catch {
                    // Pairing remains usable on a transient network failure; the
                    // normal child-state poll retries this recovery immediately
                    // after onboarding completes.
                    MeteringFlightRecorder.emitError(
                        site: "pairing.metering_bootstrap",
                        error: error
                    )
                }
            },
            startCommandOwner: { [apiClient] deviceID in
                CommandPoller.shared.start(deviceID: deviceID, apiClient: apiClient)
            }
        )
        Task { await bootstrap.run(for: childDeviceID) }
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

    /// P4 — recovery failure surfaced to `ParentBackInInstantlyStep` so its
    /// existing phase == .failed + "Try again" UI is reachable (e.g. offline).
    private enum FamilyRecoveryError: LocalizedError {
        case nothingRecovered
        var errorDescription: String? {
            "We couldn't reconnect this device. Check your connection and try again."
        }
    }

    /// Plan 8 — returning-parent / approved-co-parent recovery. Registers THIS
    /// device as a parent device on the already-existing family via
    /// POST /family/device/register (authed, idempotent on X-Device-Id), loads
    /// the FamilyStore, persists the same UserDefaults keys the rest of the app
    /// reads, and resolves a family display name for the welcome-back copy.
    /// Returns `.success(familyName)` (name may be nil), or `.failure` (P4)
    /// when nothing was actually recovered: device-register failed AND the
    /// family aggregate failed to load with no cached snapshot — the offline
    /// case. Does NOT create a new family or pair a kid.
    @MainActor
    private func recoverExistingFamily() async -> Result<String?, Error> {
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

        // P4: recovery FAILED when the device didn't register AND the family
        // aggregate didn't load (no cached snapshot either) — nothing was
        // recovered, so the welcome-back screen must show "Try again" instead
        // of a false "You're back in.".
        if registered == nil, familyStore.family == nil,
           case .failed = familyStore.state {
            return .failure(FamilyRecoveryError.nothingRecovered)
        }
        return .success(familyStore.family?.display_name)
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
