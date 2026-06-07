import SwiftUI

// SCAFFOLD-ONLY parent placeholder screens for onboarding v2.
//
// One thin wrapper per v2 parent screen (spec §7.1). Each renders the shared
// `OnboardingV2PlaceholderView` with the mockup's title + purpose + phase, so
// the screen is recognizable against `2026-06-03-onboarding-flow-v2-mockup.html`.
// Titles/subtitles are lifted from that mockup's JS screen data.
//
// Step counter convention: the parent v2 primary chain is numbered as a
// 12-step flow for human legibility —
//   1 welcome · 2 modeSelect · 3 signIn · 4 profile · 5 newOrJoin · 6 pairScan
//   · 7 connected · 8 waitingForKid · 9 setPasscode · 10 firstActions
//   · 11 itWorks · 12 done
// (welcome/modeSelect/done reuse their own existing views.)

private let parentTotal = 12

// MARK: - 3 · Sign in

struct ParentSignInStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: parentTotal,
            title: "Create your parent account",
            subtitle: "This account owns your family and lets you recover it on a new phone.",
            note: "Sign in with Apple / Google · POST /auth/apple · /auth/google",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 4 · Your profile

struct ParentProfileStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: "Tell us about you",
            subtitle: "A few details for your account — name, birthday, gender.",
            note: "PUT /me/profile",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 5 · New or join

struct ParentNewOrJoinStep: View {
    /// Scaffold only routes the "Start a new family" path. The "Join existing"
    /// branch (parentJoinExisting / parentBackInInstantly) is deferred.
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "2 · Accounts",
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "New family — or join an existing one",
            subtitle: "Start a new family (pair a kid's phone next), or returning parents add this phone without re-onboarding.",
            note: "Scaffold routes the \"Start a new family\" path → pair next.",
            primaryLabel: "Start a new family",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 6 · Scan to pair

struct ParentPairScanStep: View {
    /// Primary advance = QR scan ok. The "Enter 6-digit code instead" fallback
    /// jumps to the existing `parentPairingCode` step.
    let onContinue: () -> Void
    var onEnterCodeInstead: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            OnboardingV2PlaceholderView(
                side: .parent,
                phase: "2 · Pair",
                stepIndex: 6,
                stepTotal: parentTotal,
                title: "Scan the kid's code",
                subtitle: "Point your camera at the QR on the kid's phone. (QR + 6-digit fallback.)",
                note: "POST /family/pair (Bearer)",
                primaryLabel: "Simulate scan ok",
                onContinue: onContinue,
                onBack: onBack
            )
            if let onEnterCodeInstead {
                Button("Enter 6-digit code instead", action: onEnterCodeInstead)
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                    .padding(.bottom, Spacing.section)
            }
        }
        .background(Color.evSurface)
    }
}

// MARK: - 7 · Connected (parent)

struct ParentConnectedStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "2 · Pair",
            stepIndex: 7,
            stepTotal: parentTotal,
            title: "Connected to your kid",
            subtitle: "Now the kid grants a few permissions on their phone. We'll wait.",
            note: "Uses pair response kid_display_name",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 8 · Waiting for kid

struct ParentWaitingForKidStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "2 · Pair",
            stepIndex: 8,
            stepTotal: parentTotal,
            title: "Waiting for your kid…",
            subtitle: "Complete the steps on the kid's phone to continue.",
            note: "Polls /family/pairing-status kid_onboarding_phase; advances at \"ready\"",
            primaryLabel: "Simulate kid ready",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 14 · Tamper passcode

struct ParentSetPasscodeV2Step: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "5 · Parent finish",
            stepIndex: 9,
            stepTotal: parentTotal,
            title: "Lock the Screen Time settings",
            subtitle: "Set an iOS Screen Time passcode the kid doesn't know.",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 15 · First actions

struct ParentFirstActionsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "5 · Parent finish",
            stepIndex: 10,
            stepTotal: parentTotal,
            title: "Send your first block (test)",
            subtitle: "A live end-to-end test before you're done — make sure it goes through.",
            note: "POST /parent/child-app-catalog/lock · POST /parent/reflection/trigger",
            primaryLabel: "Send test block",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}

// MARK: - 16 · It works

struct ParentItWorksStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    var body: some View {
        OnboardingV2PlaceholderView(
            side: .parent,
            phase: "5 · Parent finish",
            stepIndex: 11,
            stepTotal: parentTotal,
            title: "It works — the test pays off",
            subtitle: "The kid's phone shows the block land, by bundle-id.",
            note: "Polls ack-status + /parent/state (lock_applied_at)",
            onContinue: onContinue,
            onBack: onBack
        )
    }
}
