import SwiftUI

enum OnboardingStep: Equatable {
    case welcome
    case modeSelect

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

    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("appMode") private var appMode: String = ""

    @State private var step: OnboardingStep = .welcome

    // Shared state threaded between steps
    @State private var childName: String = ""
    @State private var protectionMode: String = "max"
    @State private var pairingCode: String = ""
    @State private var familyID: UUID? = nil
    @State private var parentDeviceID: UUID? = nil
    @State private var childDeviceID: UUID? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            stepBody

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
                            step = .parentProtectionLevel
                        case .child:
                            appMode = "child"
                            step = .childEnterPairingCode
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

            // MARK: - Parent flow

            case .parentAddChild:
                // Legacy case kept for enum compatibility; route straight through
                Color.clear.onAppear { step = .parentProtectionLevel }

            case .parentProtectionLevel:
                ProtectionLevelStep(mode: $protectionMode) { step = .parentPairingCode }

            case .parentPairingCode:
                PairingCodeStep(
                    childName: $childName,
                    protectionMode: $protectionMode,
                    familyID: $familyID,
                    parentDeviceID: $parentDeviceID,
                    pairingCode: $pairingCode
                ) {
                    step = protectionMode == "max" ? .parentMaxWhyChildAppleID : .parentStdSetPasscode
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
}
