import SwiftUI

// Onboarding v2 — PARENT-side screens (spec §7.1).
//
// Real SwiftUI translations of the parent device screens in the v2 mockup
//   docs/superpowers/specs/2026-06-03-onboarding-flow-v2-mockup.html
// Every screen consumes ONLY the tokens + chrome from `OnboardingV2Theme.swift`
// so it stays pixel-aligned with the prototype. Data is intentionally MOCK
// (sample name "Morgan", kid "Liam", code "4 8 2 9 1 0", a fake QR/scan box) —
// the wiring lives in the coordinator, which passes the onContinue / onBack /
// onEnterCodeInstead closures these views call.
//
// The struct NAMES are load-bearing (the coordinator renders them by name); only
// the bodies are real now. Step counter convention: the parent v2 primary chain
// is numbered as a 12-step flow for human legibility —
//   1 welcome · 2 modeSelect · 3 signIn · 4 profile · 5 newOrJoin · 6 pairScan
//   · 7 connected · 8 waitingForKid · 9 setPasscode · 10 firstActions
//   · 11 itWorks · 12 done
// (welcome/modeSelect/done reuse their own existing views.)

private let parentTotal = 12

// MARK: - 3 · Sign in

/// Mockup M[2].parent — "Create your parent account": Apple / Google / email
/// sign-in buttons + "already have an account?" footnote.
struct ParentSignInStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: parentTotal,
            title: "Create your parent account",
            subtitle: "This account owns your family and lets you recover it on a new phone.",
            dotsCount: parentTotal,
            dotsCurrent: 2,
            content: {
                VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                    // Apple — black fill, white label (mockup `.cta{background:#000}`).
                    OnboardingV2PrimaryButton(
                        "Sign in with Apple",
                        systemImage: "apple.logo",
                        fill: .black,
                        action: onContinue
                    )
                    // Google — white fill, dark label, hairline border.
                    Button(action: onContinue) {
                        HStack(spacing: 8) {
                            Text("G").font(.system(size: 15, weight: .bold))
                            Text("Continue with Google")
                        }
                        .font(OnboardingV2Theme.Typography.cta)
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, OnboardingV2Theme.Metrics.ctaPaddingVertical)
                        .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
                        .background(
                            RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                             style: .continuous)
                                .fill(OnboardingV2Theme.Palette.surfaceLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                             style: .continuous)
                                .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    OnboardingV2SecondaryButton("Continue with email",
                                                systemImage: "envelope",
                                                action: onContinue)

                    Text("Already have an account? Sign in to join your family.")
                        .onboardingV2BodyXS()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.md)
                }
            },
            footer: {
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 4 · Your profile

/// Mockup M[3].parent — "Tell us about you": avatar + name / birthday fields +
/// gender segmented control. On advance the mockup shows the "Profile saved"
/// success state, which we surface inline before calling onContinue.
struct ParentProfileStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var saved = false

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 4,
            stepTotal: parentTotal,
            title: saved ? "Profile saved" : "Tell us about you",
            subtitle: saved ? "Great — that's everything we need."
                            : "A few details for your account.",
            dotsCount: parentTotal,
            dotsCurrent: 3,
            content: {
                if saved {
                    VStack(spacing: Spacing.lg) {
                        OnboardingV2SuccessCheck(role: .parent, size: 54)
                        Text("Profile saved").onboardingV2BodyStrong()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.section)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        OnboardingV2AvatarPicker(emoji: "🙂", role: .parent)
                            .frame(maxWidth: .infinity)

                        OnboardingV2LabeledField(label: "NAME", value: "Morgan", showsCursor: true)
                        OnboardingV2LabeledField(label: "BIRTHDAY", value: "March 14, 1989",
                                                 trailingSystemImage: "calendar")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("GENDER").onboardingV2FieldLabel()
                            OnboardingV2Segmented(options: ["Female", "Male", "Other"],
                                                  selectedIndex: 0)
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .parent) {
                    if saved { onContinue() } else { withAnimation { saved = true } }
                }
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 5 · New or join

/// Mockup M[4].parent — "Welcome, Morgan": two choice cards — start a new family
/// (selected) vs join an existing one. The scaffold only routes the "new" path.
struct ParentNewOrJoinStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var startNew = true

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "Welcome, Morgan",
            subtitle: "Start fresh, or pick up where you left off.",
            dotsCount: parentTotal,
            dotsCurrent: 4,
            content: {
                VStack(spacing: Spacing.lg) {
                    OnboardingV2ChoiceCard(
                        emoji: "✨",
                        title: "Start a new family",
                        subtitle: "Pair a kid's phone next",
                        selected: startNew,
                        role: .parent
                    ) { startNew = true }

                    OnboardingV2ChoiceCard(
                        emoji: "👨‍👩‍👧",
                        title: "Join \u{201C}Smith Family\u{201D}",
                        subtitle: "Liam · already set up — add this phone",
                        selected: !startNew,
                        role: .parent
                    ) { startNew = false }
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Start a new family", role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 6 · Scan to pair

/// Mockup M[5].parent — "Scan Liam's code": a camera scan frame (dark box,
/// white corner reticle, sweeping green line) + a 6-digit-code fallback.
struct ParentPairScanStep: View {
    let onContinue: () -> Void
    var onEnterCodeInstead: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 6,
            stepTotal: parentTotal,
            title: "Scan Liam's code",
            subtitle: "Point your camera at the QR on Liam's phone.",
            dotsCount: parentTotal,
            dotsCurrent: 5,
            content: {
                VStack(spacing: Spacing.lg) {
                    OnboardingV2ScanFrame()
                        .frame(maxWidth: .infinity)
                    // Primary advance = scan ok (mock).
                    OnboardingV2PrimaryButton("Simulate scan", role: .parent, action: onContinue)
                }
            },
            footer: {
                if let onEnterCodeInstead {
                    OnboardingV2SecondaryButton("Enter 6-digit code instead",
                                                action: onEnterCodeInstead)
                }
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 7 · Connected (parent)

/// Mockup M[6].parent — "Connected to Liam": big green check, then wait while
/// the kid grants permissions.
struct ParentConnectedStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 7,
            stepTotal: parentTotal,
            title: "Linked",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 6,
            content: {
                VStack(spacing: Spacing.xl) {
                    OnboardingV2SuccessCheck(role: .parent, size: 62)
                    Text("Connected to Liam").onboardingV2TitleL()
                    Text("Now Liam grants a few permissions on their phone. We'll wait.")
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 8 · Waiting for kid

/// Mockup M[7].parent — the parent column shows `waiting("Liam")`: a spinner +
/// "Waiting for Liam…" while the kid completes their side.
struct ParentWaitingForKidStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 8,
            stepTotal: parentTotal,
            title: "Almost there",
            subtitle: nil,
            dotsCount: parentTotal,
            dotsCurrent: 7,
            content: {
                OnboardingV2WaitingSpinner(
                    name: "Liam",
                    subtitle: "Complete the steps on Liam's phone to continue."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                // Mock advance — coordinator's "kid ready" hand-off.
                OnboardingV2PrimaryButton("Simulate kid ready", role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 9 · Tamper passcode

/// Mockup M[14].parent — "One safety lock": 3 numbered steps to set an iOS
/// Screen Time passcode, then deep-link out / confirm.
struct ParentSetPasscodeV2Step: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 9,
            stepTotal: parentTotal,
            title: "One safety lock",
            subtitle: "Set a Screen Time passcode Liam doesn't know — it stops them turning Evlin off.",
            dotsCount: parentTotal,
            dotsCurrent: 8,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    OnboardingV2NumberedStep(number: 1, text: "Open Settings → Screen Time")
                    OnboardingV2NumberedStep(number: 2, text: "Tap \u{201C}Lock Screen Time Settings\u{201D}")
                    OnboardingV2NumberedStep(number: 3, text: "Pick a 4-digit code Liam won't guess")
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Open Screen Time settings", role: .parent, action: onContinue)
                OnboardingV2SecondaryButton("I've set it", action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 10 · First actions (the payoff test)

/// Mockup M[15].parent — "Send your first block": a chat exchange (parent asks,
/// Evlin confirms) + an APP→BLOCK explainer card. The live end-to-end test.
struct ParentFirstActionsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 10,
            stepTotal: parentTotal,
            title: "Send your first block",
            subtitle: "Let's make sure it actually goes through. Tell Evlin in plain words:",
            dotsCount: parentTotal,
            dotsCurrent: 9,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        OnboardingV2ChatBubble(.me, text: "Block TikTok for 5 minutes")
                        OnboardingV2ChatBubble(
                            .evlin,
                            attributed: {
                                var s = AttributedString("Blocking TikTok for 5 min.")
                                s.font = OnboardingV2Theme.Typography.bodyStrong
                                var t = AttributedString(
                                    "\nIt'll be hidden by name on Liam's phone — watch their screen to confirm it landed.")
                                t.font = OnboardingV2Theme.Typography.body
                                return s + t
                            }()
                        )
                    }

                    OnboardingV2Card {
                        HStack(alignment: .top, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                            OnboardingV2Badge("APP→BLOCK", style: .success)
                            Text("Single app → block (bundle-id). Say \u{201C}block Games\u{201D} instead → that shields the whole category.")
                                .onboardingV2BodyXS()
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Send block", systemImage: "paperplane.fill",
                                          role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 11 · It works

/// Mockup M[16].parent — "Sent ✓": a receipt card for the landed block, with an
/// "End now" affordance and the "you'll get a ping" footnote.
struct ParentItWorksStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 11,
            stepTotal: parentTotal,
            title: "Sent",
            subtitle: "Liam's TikTok is blocked for 5 minutes. Check their phone — it landed.",
            dotsCount: parentTotal,
            dotsCurrent: 10,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                            OnboardingV2AppIcon(letter: "T", fill: .black)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TikTok · blocked").onboardingV2BodyStrong()
                                Text("Unblocks at 9:46 · you can end it anytime").onboardingV2BodyXS()
                            }
                            OnboardingV2SecondaryButton("End now", action: {})
                                .padding(.top, Spacing.sm)
                        }
                    }

                    Text("You'll get a ping if Liam asks to unblock.")
                        .onboardingV2BodyXS()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - Local screen primitives
//
// Small reusable subviews for mockup elements not already in OnboardingV2Theme:
// the labeled-field row (.field), the segmented control (seg()), choice/role
// cards (roleCard()), the avatar picker, success check, waiting spinner, scan
// frame, numbered step row (stepRow()), chat bubble, app icon, and badge.
// They consume ONLY OnboardingV2Theme tokens, so they stay mockup-faithful.

/// `.body-xs` field caption, e.g. "NAME" (letter-spacing ~.4px, uppercase).
private extension Text {
    func onboardingV2FieldLabel() -> some View {
        self.font(OnboardingV2Theme.Typography.bodyXS)
            .tracking(0.4)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

/// "Back" ghost link reused as the last footer row (the mockup nav `‹ Back`).
private struct OnboardingV2BackLink: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Back")
                .font(OnboardingV2Theme.Typography.navButton)
                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// `.field` — caption + a rounded surface-container row holding a value, with an
/// optional blinking cursor or trailing glyph.
private struct OnboardingV2LabeledField: View {
    let label: String
    let value: String
    var showsCursor: Bool = false
    var trailingSystemImage: String? = nil

    @State private var cursorOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).onboardingV2FieldLabel()
            HStack {
                HStack(spacing: 1) {
                    Text(value)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                    if showsCursor {
                        Rectangle()
                            .fill(OnboardingV2Theme.Palette.primary)
                            .frame(width: 2, height: 19)
                            .opacity(cursorOn ? 1 : 0)
                            .onAppear {
                                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                    cursorOn = false
                                }
                            }
                    }
                }
                Spacer(minLength: 0)
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .foregroundStyle(OnboardingV2Theme.Palette.outline)
                }
            }
            .padding(.vertical, OnboardingV2Theme.Metrics.fieldPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.fieldPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.fieldCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
        }
    }
}

/// `seg()` — the 3-up segmented control; the selected pill is `--primary`.
private struct OnboardingV2Segmented: View {
    let options: [String]
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                let on = i == selectedIndex
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? OnboardingV2Theme.Palette.onPrimary
                                        : OnboardingV2Theme.Palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(on ? OnboardingV2Theme.Palette.primary
                                     : OnboardingV2Theme.Palette.surfaceContainer)
                    )
            }
        }
    }
}

/// The 66×66 circular avatar with the role-tinted "+" badge (profile screens).
private struct OnboardingV2AvatarPicker: View {
    let emoji: String
    let role: OnboardingV2Role

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(OnboardingV2Theme.Palette.surfaceContainer)
                .frame(width: 66, height: 66)
                .overlay(Text(emoji).font(.system(size: 26)))
            Circle()
                .fill(role.accent)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                )
                .overlay(Circle().stroke(OnboardingV2Theme.Palette.surface, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }
}

/// `roleCard()` inside a `.card` — emoji tile + title/subtitle + selected check
/// or chevron, with a role-tinted 2px border when selected.
private struct OnboardingV2ChoiceCard: View {
    let emoji: String
    let title: String
    let subtitle: String
    let selected: Bool
    let role: OnboardingV2Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceContainer)
                    .frame(width: 42, height: 42)
                    .overlay(Text(emoji).font(.system(size: 22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).onboardingV2BodyStrong()
                    Text(subtitle).onboardingV2BodyXS()
                }
                Spacer(minLength: 0)
                if selected {
                    OnboardingV2SuccessCheck(role: role, size: 22)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OnboardingV2Theme.Palette.outline)
                }
            }
            .padding(OnboardingV2Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .fill(OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .stroke(selected ? role.accent : OnboardingV2Theme.Palette.outlineVariant,
                            lineWidth: selected ? 2 : 1)
            )
            .shadow(color: OnboardingV2Theme.Shadow.premiumColor,
                    radius: OnboardingV2Theme.Shadow.premiumRadius,
                    x: 0, y: OnboardingV2Theme.Shadow.premiumY)
        }
        .buttonStyle(.plain)
    }
}

/// `.check` — the filled success disc with a white ✓ (sized for headers + rows).
private struct OnboardingV2SuccessCheck: View {
    var role: OnboardingV2Role = .parent
    let size: CGFloat

    private var fill: Color { OnboardingV2Theme.Palette.secondary } // mockup `.check{background:var(--secondary)}`

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// `waiting()` — spinner + "Waiting for <name>…" + sub-line.
private struct OnboardingV2WaitingSpinner: View {
    let name: String
    let subtitle: String

    @State private var spin = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(OnboardingV2Theme.Palette.primary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 46, height: 46)
                .background(
                    Circle().stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 3)
                )
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
            Text("Waiting for \(name)…").onboardingV2BodyStrong()
            Text(subtitle)
                .onboardingV2Body()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
    }
}

/// `scanFrame()` — a dark camera box with a white corner reticle and a sweeping
/// green scan line.
private struct OnboardingV2ScanFrame: View {
    @State private var sweepDown = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OnboardingV2Theme.Palette.darkScreen)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .padding(26)
            // Sweeping green line.
            Rectangle()
                .fill(OnboardingV2Theme.Palette.secondary)
                .frame(height: 2)
                .shadow(color: OnboardingV2Theme.Palette.secondary, radius: 6)
                .padding(.horizontal, 26)
                .offset(y: sweepDown ? 69 : -69)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: sweepDown)
                .onAppear { sweepDown = true }
        }
        .frame(width: 208, height: 208)
    }
}

/// `stepRow()` — a numbered disc (`--primary`) + a body-strong instruction.
private struct OnboardingV2NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
            Circle()
                .fill(OnboardingV2Theme.Palette.primary)
                .frame(width: 26, height: 26)
                .overlay(
                    Text("\(number)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                )
            Text(text).onboardingV2BodyStrong()
        }
    }
}

/// `.chat-bubble` — the me (navy, right) / Evlin (surface-container, left) bubbles.
private struct OnboardingV2ChatBubble: View {
    enum Speaker { case me, evlin }

    let speaker: Speaker
    private let plain: String?
    private let rich: AttributedString?

    init(_ speaker: Speaker, text: String) {
        self.speaker = speaker
        self.plain = text
        self.rich = nil
    }

    init(_ speaker: Speaker, attributed: AttributedString) {
        self.speaker = speaker
        self.plain = nil
        self.rich = attributed
    }

    private var isMe: Bool { speaker == .me }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 40) }
            Group {
                if let rich { Text(rich) } else { Text(plain ?? "") }
            }
            .font(OnboardingV2Theme.Typography.body)
            .foregroundStyle(isMe ? OnboardingV2Theme.Palette.onPrimary
                                  : OnboardingV2Theme.Palette.onSurface)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isMe ? OnboardingV2Theme.Palette.primary
                               : OnboardingV2Theme.Palette.surfaceContainer)
            )
            if !isMe { Spacer(minLength: 40) }
        }
    }
}

/// `.app-icon` — the 38×38 rounded glyph tile (e.g. "T" on black for TikTok).
private struct OnboardingV2AppIcon: View {
    let letter: String
    let fill: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .frame(width: 38, height: 38)
            .overlay(
                Text(letter)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// `.badge` — the small pill chip; success = green, warn = amber, new = blue.
private struct OnboardingV2Badge: View {
    enum Style { case success, warn, new }

    let text: String
    let style: Style

    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    private var fg: Color {
        switch style {
        case .success: return OnboardingV2Theme.Palette.secondary
        case .warn:    return Color(hex: 0x856404)
        case .new:     return Color(hex: 0x1B53B3)
        }
    }
    private var bg: Color {
        switch style {
        case .success: return OnboardingV2Theme.Palette.secondaryContainer
        case .warn:    return Color(hex: 0xFFF3CD)
        case .new:     return Color(hex: 0xE7F0FF)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(fg)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(bg))
    }
}
