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
}

struct OnboardingCoordinator: View {

    @EnvironmentObject var apiClient: APIClient

    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    @State private var step: OnboardingStep = .welcome

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
                    step = .parentPairingCode
                }
                #endif

            #if DEBUG
            // Debug escape hatch — always available during onboarding
            Menu {
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
                    // Pairing succeeded → next: parent picks protection mode.
                    // The mode-specific (Max vs Std) flow branches inside
                    // .parentProtectionLevel's onContinue, AFTER we've had
                    // a chance to PUT /family/{id}/protection-mode.
                    step = .parentProtectionLevel
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
                GrantPermissionStep(
                    childDeviceID: childDeviceID ?? OnboardingDemoPlaceholders.childDeviceUUID,
                    protectionMode: protectionMode
                ) {
                    step = .childDeletionProtection
                }

            case .childDeletionProtection:
                DeletionProtectionStep { step = .childCategoryDefaults }

            case .childCategoryDefaults:
                CategoryDefaultsStep {
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
