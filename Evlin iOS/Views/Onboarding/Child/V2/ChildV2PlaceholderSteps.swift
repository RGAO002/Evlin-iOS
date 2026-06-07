import SwiftUI

// SCAFFOLD-ONLY kid placeholder screens for onboarding v2.
//
// One thin wrapper per v2 kid screen (spec §7.2). Each renders the shared
// `OnboardingV2PlaceholderView` with the mockup's title + purpose + phase.
// Titles/subtitles are lifted from `2026-06-03-onboarding-flow-v2-mockup.html`.
//
// Step counter convention: the kid v2 primary chain is numbered as an 11-step
// flow for human legibility —
//   1 welcome · 2 modeSelect · 3 childProfile · 4 childShowCode · 5 childConnected
//   · 6 childConsentDisclosure · 7 childGrantPermission · 8 childAllowNotifications
//   · 9 childDeletionProtection · 10 childLockableHub · 11 childReady
// (welcome/modeSelect, plus grantPermission/deletionProtection/ready, reuse
// their own existing views.)

private let childTotal = 11

// MARK: - 3 · Profile (kid)

struct ChildProfileStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: childTotal,
            title: "Set up your profile",
            subtitle: "So Evlin and your parent know it's you — photo, name, birthday, gender.",
            note: "Captured locally; sent on /family/create",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 5/6 · Show code (kid)

struct ChildShowCodeStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "2 · Pair",
            stepIndex: 4,
            stepTotal: childTotal,
            title: "Show this to your parent",
            subtitle: "They'll scan it from their phone. (QR + a 6-digit code fallback.)",
            note: "POST /family/create (+QR) · polls GET /family/pairing-status",
            primaryLabel: "Simulate parent paired",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 7 · Connected (kid)

struct ChildConnectedStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "2 · Pair",
            stepIndex: 5,
            stepTotal: childTotal,
            title: "You're linked to your parent",
            subtitle: "A few quick things, then you're done.",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 8 · What Evlin can see (consent disclosure)

struct ChildConsentDisclosureStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "3 · Kid consent",
            stepIndex: 6,
            stepTotal: childTotal,
            title: "What Evlin can see",
            subtitle: "The honest-disclosure moment — you consent with eyes open.",
            note: "Device-monitoring consent (full screen)",
            primaryLabel: "I understand",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 10 · Allow notifications

struct ChildAllowNotificationsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "3 · Kid consent",
            stepIndex: 8,
            stepTotal: childTotal,
            title: "Allow notifications",
            subtitle: "So alerts can reach you — needed for lock / unlock-request pushes.",
            note: "registerAPNsToken",
            primaryLabel: "Allow notifications",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 12 · Choose what to lock (lockable hub)

struct ChildLockableHubStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .child,
            phase: "4 · Lockable",
            stepIndex: 10,
            stepTotal: childTotal,
            title: "Choose what Evlin can lock",
            subtitle: "The real add-category / app / list screen — with \"Skip for now\".",
            note: "AddAppFlowView + ChildFirstSavedListStep (retires CategoryDefaultsStep)",
            primaryLabel: "Skip for now",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}
