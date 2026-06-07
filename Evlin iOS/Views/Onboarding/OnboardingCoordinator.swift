import SwiftUI

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
    case parentPairScan          // mockup 6: "Scan the kid's code" (QR + 6-digit fallback)
    case parentConnected         // mockup 7: "Connected" (parent side)
    case parentWaitingForKid     // polls /family/pairing-status kid_onboarding_phase
    case parentSetPasscode       // mockup 14: "Lock the Screen Time settings"
    case parentFirstActions      // mockup 15: "Send your first block (test)"
    case parentItWorks           // mockup 16: "It works — the test pays off"

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

    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    @State private var step: OnboardingStep = .welcome

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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            stepBody
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
                    EvlinDemoShortcuts.clearFlag()
                    UserDefaults.standard.removeObject(forKey: "onboardingComplete")
                    UserDefaults.standard.removeObject(forKey: "appMode")
                    // v2 spec §7.4: also clear the v2 account/profile ids.
                    for key in ["evlin.accountID", "evlin.parentProfileID", "evlin.childProfileID"] {
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

            // MARK: - Onboarding v2 (scaffold) — PARENT
            //
            // Tappable placeholders only. next/back drive the v2 parent chain
            // (spec §7.1): signIn → profile → newOrJoin → pairScan → connected
            // → waitingForKid → setPasscode → firstActions → itWorks → done.

            case .parentSignIn:
                ParentSignInStep(
                    onContinue: { step = .parentProfile },
                    onBack: { step = .modeSelect }
                )

            case .parentProfile:
                ParentProfileStep(
                    onContinue: { step = .parentNewOrJoin },
                    onBack: { step = .parentSignIn }
                )

            case .parentNewOrJoin:
                ParentNewOrJoinStep(
                    onContinue: { step = .parentPairScan },
                    onBack: { step = .parentProfile }
                )

            case .parentPairScan:
                ParentPairScanStep(
                    onContinue: { step = .parentConnected },
                    // 6-digit fallback reuses the existing pairing-code step,
                    // which (in v2) routes onward to parentConnected.
                    onEnterCodeInstead: { step = .parentPairingCode },
                    onBack: { step = .parentNewOrJoin }
                )

            case .parentConnected:
                ParentConnectedStep(
                    onContinue: { step = .parentWaitingForKid },
                    onBack: { step = .parentPairScan }
                )

            case .parentWaitingForKid:
                ParentWaitingForKidStep(
                    onContinue: { step = .parentSetPasscode },
                    onBack: { step = .parentConnected }
                )

            case .parentSetPasscode:
                ParentSetPasscodeV2Step(
                    onContinue: { step = .parentFirstActions },
                    onBack: { step = .parentWaitingForKid }
                )

            case .parentFirstActions:
                ParentFirstActionsStep(
                    onContinue: { step = .parentItWorks },
                    onBack: { step = .parentSetPasscode }
                )

            case .parentItWorks:
                ParentItWorksStep(
                    onContinue: { step = .parentDone },
                    onBack: { step = .parentFirstActions }
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
                    onContinue: { step = .childShowCode },
                    onBack: { step = .modeSelect }
                )

            case .childShowCode:
                ChildShowCodeStep(
                    onContinue: { step = .childConnected },
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
                    onContinue: { step = .childReady },
                    onBack: { step = .childDeletionProtection }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
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
