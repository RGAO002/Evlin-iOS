import SwiftUI

// Onboarding v2 — KID screens (real UI).
//
// A faithful SwiftUI translation of the kid-side device screens in the v2 mockup
//   docs/superpowers/specs/2026-06-03-onboarding-flow-v2-mockup.html
// Every screen consumes ONLY the tokens + components from `OnboardingV2Theme`
// (Palette / Metrics / Typography + OnboardingV2ScreenContainer / Card / buttons)
// so the flow stays pixel-aligned with the prototype.
//
// The view-struct NAMES + initializers are unchanged — the coordinator renders
// each by name (onContinue advances the v2 kid chain, onBack steps back). Only
// the bodies were promoted from the generic placeholder to real screens.
//
// These render frameless (`embeddedRole:` → showsDeviceFrame:false) because the
// coordinator already presents each step full-screen (matching the v1 kid views
// like ChildReadyStep) — there is no host device bezel to double up on.
//
// Step counter convention: the kid v2 primary chain is numbered as an 11-step
// flow for human legibility —
//   1 welcome · 2 modeSelect · 3 childProfile · 4 childShowCode · 5 childConnected
//   · 6 childConsentDisclosure · 7 childGrantPermission · 8 childAllowNotifications
//   · 9 childDeletionProtection · 10 childLockableHub · 11 childReady
// (welcome/modeSelect, plus grantPermission/deletionProtection/ready, reuse
// their own existing views.)
//
// STATIC/MOCK data: sample kid name "Liam", birthday "August 2, 2013", a sample
// 6-digit pairing code "4 8 2 9 1 0", and a deterministic faux QR box. None of
// this is wired to the network in these onboarding-scaffold screens.

private let childTotal = 11
private let kidGreen = OnboardingV2Theme.Palette.secondary

// MARK: - Shared local helpers (kid screens only)

/// `.field` — surface-container box, 13px radius, 1px outline-variant border,
/// 16/600 value text. Used by the profile NAME / BIRTHDAY rows.
private struct OnboardingV2Field<Trailing: View>: View {
    let value: String
    var showsCursor: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: showsCursor ? .semibold : .medium))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            if showsCursor {
                BlinkingCursor()
            }
            Spacer(minLength: 0)
            trailing()
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

extension OnboardingV2Field where Trailing == EmptyView {
    init(value: String, showsCursor: Bool = false) {
        self.init(value: value, showsCursor: showsCursor, trailing: { EmptyView() })
    }
}

/// `.field .cursor{width:2px;height:19px;background:--primary;animation:blink}`.
private struct BlinkingCursor: View {
    @State private var visible = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(OnboardingV2Theme.Palette.primary)
            .frame(width: 2, height: 19)
            .opacity(visible ? 1 : 0)
            .onAppear {
                // `.field .cursor{animation:blink 1s step-end infinite}` — toggle
                // visibility every 0.5s for the steady-blink terminal cursor.
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    visible.toggle()
                }
            }
    }
}

/// Field label, e.g. `NAME` — `.body-xs` uppercased with a touch of tracking.
private struct OnboardingV2FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(OnboardingV2Theme.Typography.bodyXS)
            .tracking(0.4)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

/// `seg()` — one cell of the gender segmented control. Selected → navy fill +
/// white text; unselected → surface-container + variant text.
private struct OnboardingV2Segment: View {
    let title: String
    let selected: Bool
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? OnboardingV2Theme.Palette.onPrimary
                                      : OnboardingV2Theme.Palette.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? OnboardingV2Theme.Palette.primary
                                   : OnboardingV2Theme.Palette.surfaceContainer)
            )
    }
}

/// A "can / can't" disclosure row — green ✓ or red ✕ glyph + a line of copy.
private struct OnboardingV2DisclosureRow: View {
    let allowed: Bool
    let text: String
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: allowed ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(allowed ? OnboardingV2Theme.Palette.secondary
                                         : OnboardingV2Theme.Palette.error)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 13.5, weight: allowed ? .medium : .regular))
                .foregroundStyle(allowed ? OnboardingV2Theme.Palette.onSurface
                                         : OnboardingV2Theme.Palette.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 7)
    }
}

/// `addRow()` — a tappable "Add a …" list row: tinted emoji tile, title +
/// subtitle, trailing "+" chip. Matches `.list-item` (14px radius, premium shadow).
private struct OnboardingV2AddRow: View {
    let emoji: String
    let title: String
    let subtitle: String
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.1))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                Text(subtitle)
                    .onboardingV2BodyXS()
            }
            Spacer(minLength: 0)
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(OnboardingV2Theme.Palette.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(OnboardingV2Theme.Palette.surfaceContainer))
        }
        .padding(.vertical, OnboardingV2Theme.Metrics.listItemPaddingVertical)
        .padding(.horizontal, OnboardingV2Theme.Metrics.listItemPaddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.listItemCornerRadius,
                             style: .continuous)
                .fill(OnboardingV2Theme.Palette.surfaceLowest)
        )
        .shadow(color: OnboardingV2Theme.Shadow.premiumColor,
                radius: OnboardingV2Theme.Shadow.premiumRadius,
                x: 0, y: OnboardingV2Theme.Shadow.premiumY)
    }
}

/// A small back ("‹ Back") affordance, rendered under the primary CTA so each
/// screen keeps a way to step back through the v2 chain.
private struct OnboardingV2BackLink: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text("Back").font(OnboardingV2Theme.Typography.navButton)
            }
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// A deterministic faux-QR box (finder squares + pseudo-random data modules) so
/// the kid screens show a believable code without a real encoder. Mirrors the
/// mockup's `qr()` SVG: 21×21 modules in `--primary` on white, 8px radius.
private struct OnboardingV2FauxQR: View {
    var size: CGFloat = 150
    private let n = 21

    private func isFinder(_ x: Int, _ y: Int) -> Bool {
        func inFinder(_ ox: Int, _ oy: Int) -> Bool {
            let lx = x - ox, ly = y - oy
            guard (0...6).contains(lx), (0...6).contains(ly) else { return false }
            let ring = lx == 0 || lx == 6 || ly == 0 || ly == 6
            let core = (2...4).contains(lx) && (2...4).contains(ly)
            return ring || core
        }
        return inFinder(0, 0) || inFinder(0, n - 7) || inFinder(n - 7, 0)
    }

    private func inFinderZone(_ x: Int, _ y: Int) -> Bool {
        (x < 8 && y < 8) || (x < 8 && y >= n - 8) || (x >= n - 8 && y < 8)
    }

    private func isData(_ x: Int, _ y: Int) -> Bool {
        guard !inFinderZone(x, y) else { return false }
        return ((x * x + y * 3 + x * y) % 5) < 2
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let cell = canvasSize.width / CGFloat(n)
            for y in 0..<n {
                for x in 0..<n {
                    let on = isFinder(x, y) || isData(x, y)
                    guard on else { continue }
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                      width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(OnboardingV2Theme.Palette.primary))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 3 · Profile (kid)  ·  mockup: "Set up your profile"

struct ChildProfileStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Accounts",
            stepIndex: 3,
            stepTotal: childTotal,
            title: "Set up your profile",
            subtitle: "So Evlin and your parent know it's you.",
            content: {
                VStack(spacing: 13) {
                    // Avatar with the "+" add badge.
                    ZStack(alignment: .bottomTrailing) {
                        Text("🧒")
                            .font(.system(size: 26))
                            .frame(width: 66, height: 66)
                            .background(Circle().fill(OnboardingV2Theme.Palette.surfaceContainer))
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(kidGreen))
                            .overlay(Circle().stroke(OnboardingV2Theme.Palette.surface, lineWidth: 2))
                    }
                    .padding(.bottom, 1)

                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "NAME")
                        OnboardingV2Field(value: "Liam", showsCursor: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "BIRTHDAY")
                        OnboardingV2Field(value: "August 2, 2013") {
                            Image(systemName: "calendar")
                                .font(.system(size: 15))
                                .foregroundStyle(OnboardingV2Theme.Palette.outline)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "GENDER")
                        HStack(spacing: 8) {
                            OnboardingV2Segment(title: "Female", selected: false)
                            OnboardingV2Segment(title: "Male", selected: true)
                            OnboardingV2Segment(title: "Other", selected: false)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 5/6 · Show code (kid)  ·  mockup: "Show this to your parent"

struct ChildShowCodeStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 4,
            stepTotal: childTotal,
            title: "Show this to your parent",
            subtitle: "They'll scan it from their phone.",
            content: {
                VStack(spacing: 12) {
                    // QR card.
                    OnboardingV2Card {
                        HStack {
                            Spacer(minLength: 0)
                            OnboardingV2FauxQR()
                            Spacer(minLength: 0)
                        }
                    }

                    // "Or type this code" fallback card.
                    OnboardingV2Card {
                        VStack(spacing: 4) {
                            Text("OR TYPE THIS CODE")
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .tracking(1)
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                            Text("4 8 2 9 1 0")
                                .font(.system(size: 24, weight: .bold))
                                .tracking(5)
                                .foregroundStyle(OnboardingV2Theme.Palette.primary)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    // Live "waiting for parent to scan" pulse cue.
                    HStack(spacing: 8) {
                        Circle()
                            .fill(OnboardingV2Theme.Palette.tertiary)
                            .frame(width: 8, height: 8)
                        Text("Waiting for parent to scan…")
                            .onboardingV2Body()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            },
            footer: {
                // Onboarding scaffold: a primary button stands in for the
                // pairing-status poll so a human can advance the flow.
                OnboardingV2PrimaryButton("Simulate parent paired", role: .child, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 7 · Connected (kid)  ·  mockup: "You're linked to your parent"

struct ChildConnectedStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 5,
            stepTotal: childTotal,
            title: "You're linked to your parent",
            subtitle: "A few quick things, then you're done.",
            content: {
                VStack(spacing: 16) {
                    Spacer(minLength: 8)
                    // Big success check.
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(kidGreen))
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 8 · What Evlin can see (consent disclosure)
//   mockup: "Your parent wants to help with screen time"

struct ChildConsentDisclosureStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "3 · Kid consent",
            stepIndex: 6,
            stepTotal: childTotal,
            title: "Your parent wants to help with screen time",
            subtitle: "Here's exactly what that means.",
            content: {
                VStack(spacing: 12) {
                    // EVLIN CAN card.
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("EVLIN CAN")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(OnboardingV2Theme.Palette.secondary)
                                .padding(.bottom, 8)
                            OnboardingV2DisclosureRow(allowed: true, text: "See apps you & your parent add")
                            OnboardingV2DisclosureRow(allowed: true, text: "Lock or block them for set times")
                            OnboardingV2DisclosureRow(allowed: true, text: "Show you who locked & for how long")
                        }
                    }
                    // EVLIN CAN'T card.
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("EVLIN CAN'T")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(OnboardingV2Theme.Palette.error)
                                .padding(.bottom, 8)
                            OnboardingV2DisclosureRow(allowed: false, text: "Read your messages")
                            OnboardingV2DisclosureRow(allowed: false, text: "See your photos")
                            OnboardingV2DisclosureRow(allowed: false, text: "Read your full app list")
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton("I understand — continue", role: .child, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 10 · Allow notifications  ·  mockup: "Stay in the loop"

struct ChildAllowNotificationsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "3 · Kid consent",
            stepIndex: 8,
            stepTotal: childTotal,
            title: "Stay in the loop",
            subtitle: "Get a heads-up when an app is locked, or when your parent answers an unlock request.",
            content: {
                // The iOS-style system permission "sheet" preview.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Text("🔔").font(.system(size: 30))
                        Text("\u{201C}Evlin\u{201D} Would Like to\nSend You Notifications")
                            .onboardingV2TitleL()
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                        Text("Notifications may include alerts and sounds.")
                            .onboardingV2Body()
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .padding(.top, 10)
                            .padding(.bottom, 18)
                        OnboardingV2PrimaryButton("Allow", role: .child, action: onContinue)
                            .padding(.bottom, 8)
                        OnboardingV2SecondaryButton("Maybe later", action: onContinue)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(OnboardingV2Theme.Palette.surfaceLowest)
                            .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: -10)
                    )
                }
            },
            footer: {
                // The CTAs live inside the system-sheet preview above; keep only
                // the back affordance pinned in the footer row.
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 12 · Choose what to lock (lockable hub)
//   mockup: "Choose what Evlin can lock"

struct ChildLockableHubStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "4 · Lockable",
            stepIndex: 10,
            stepTotal: childTotal,
            title: "Choose what Evlin can lock",
            subtitle: "Set up the groups & apps Evlin can pause on this phone. Categories are the powerful one — they shield a whole group and any new app that joins it later.",
            content: {
                VStack(spacing: 8) {
                    OnboardingV2AddRow(emoji: "🗂️",
                                       title: "Add a category",
                                       subtitle: "Shield a group (e.g. Games) + future apps",
                                       tint: Color(hex: 0x7C4DFF))
                    OnboardingV2AddRow(emoji: "📱",
                                       title: "Add an app",
                                       subtitle: "Pick one app, confirm its label, name it",
                                       tint: Color(hex: 0x2563EB))
                    OnboardingV2AddRow(emoji: "📚",
                                       title: "Add a list",
                                       subtitle: "Group apps/categories into one target",
                                       tint: OnboardingV2Theme.Palette.tertiary)

                    // "Not sure yet?" reassurance card (primary-container).
                    HStack(alignment: .top, spacing: 10) {
                        Text("✨").font(.system(size: 16))
                        Text("Not sure yet? Skip — you can add these later (Kid mode → Apps, behind the Evlin PIN), and still just say \u{201C}block Instagram\u{201D} by name anytime.")
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.primary)
                    }
                    .padding(OnboardingV2Theme.Metrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                         style: .continuous)
                            .fill(OnboardingV2Theme.Palette.primaryContainer)
                    )
                    .padding(.top, 2)
                }
            },
            footer: {
                OnboardingV2SecondaryButton("Skip for now", action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}
