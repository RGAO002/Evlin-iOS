import SwiftUI

// MARK: - Onboarding v2 Design System — "Informed Sentinel"
//
// A faithful SwiftUI translation of the v2 onboarding HTML mockup at
//   docs/superpowers/specs/2026-06-03-onboarding-flow-v2-mockup.html
//
// Every token below is read DIRECTLY off that mockup's `:root` CSS variables and
// the in-screen component rules (.cta, .card, .field, .phase-tag, .dots-nav …).
// The mockup is the source of truth for layout / copy / colors / controls; the
// per-screen builders should consume ONLY the tokens + components declared here
// so the SwiftUI flow stays pixel-aligned with the prototype.
//
// Naming: everything lives under the `OnboardingV2Theme` namespace (tokens) plus
// a small set of `OnboardingV2*` SwiftUI views (chrome). This keeps the v2 system
// self-contained and avoids colliding with the app-wide Evlin* design tokens,
// while still re-using the shared `Color(hex:)` initializer.

// MARK: - Tokens

/// Color / metric / font tokens transcribed verbatim from the mockup CSS.
enum OnboardingV2Theme {

    // MARK: Colors (from the mockup `:root` custom properties)

    enum Palette {
        /// `--surface:#fcfcfd` — the phone-screen background (light).
        static let surface = Color(hex: 0xFCFCFD)
        /// `--surface-low:#f7f8fa` — the page background behind the device frame.
        static let surfaceLow = Color(hex: 0xF7F8FA)
        /// `--surface-container:#f1f2f4` — segmented controls, neutral chips.
        static let surfaceContainer = Color(hex: 0xF1F2F4)
        /// `--surface-lowest:#ffffff` — cards, list rows, sign-in buttons.
        static let surfaceLowest = Color.white

        /// `--on-surface:#1a1c1e` — primary text.
        static let onSurface = Color(hex: 0x1A1C1E)
        /// `--on-surface-variant:#5a5e66` — secondary / body text.
        static let onSurfaceVariant = Color(hex: 0x5A5E66)
        /// `--outline:#8e9199` — hairline icons, unselected ring.
        static let outline = Color(hex: 0x8E9199)
        /// `--outline-variant:#e2e4e9` — borders, dividers, secondary-CTA stroke.
        static let outlineVariant = Color(hex: 0xE2E4E9)

        /// `--primary:#041627` — CTA fill, parent accent, dot-on color.
        static let primary = Color(hex: 0x041627)
        /// `--primary-container:#f0f4f8` — phase-tag bg, parent label bg, info card.
        static let primaryContainer = Color(hex: 0xF0F4F8)
        /// `--on-primary:#ffffff` — text on the primary CTA.
        static let onPrimary = Color.white

        /// `--secondary:#2e7d32` — kid accent / success / green CTA.
        static let secondary = Color(hex: 0x2E7D32)
        /// `--secondary-container:#e8f5e9` — kid label bg, "can" card accents.
        static let secondaryContainer = Color(hex: 0xE8F5E9)

        /// `--tertiary:#ef6c00` — amber pulse, warn accents.
        static let tertiary = Color(hex: 0xEF6C00)
        /// `--tertiary-container:#fff3e0`.
        static let tertiaryContainer = Color(hex: 0xFFF3E0)

        /// `--error:#d32f2f` — the "can't" ✕ marks.
        static let error = Color(hex: 0xD32F2F)
        /// `--error-container:#ffebee`.
        static let errorContainer = Color(hex: 0xFFEBEE)

        // Dark-screen overrides (`.iphone.dark`) — used by the "TikTok is blocked"
        // kid screen.
        /// `.iphone.dark .screen{background:#0a0a0d}`.
        static let darkScreen = Color(hex: 0x0A0A0D)
        /// `.iphone.dark .body{color:#b9bcc4}`.
        static let darkBody = Color(hex: 0xB9BCC4)
        /// `.iphone.dark .card{background:#16161b}`.
        static let darkCard = Color(hex: 0x16161B)

        // Device-frame look (`.iphone`).
        /// `.iphone{background:#0c0c0e}` — the bezel body.
        static let deviceBody = Color(hex: 0x0C0C0E)
        /// `box-shadow:0 0 0 1.5px #2a2a2e` — the chrome ring around the bezel.
        static let deviceRing = Color(hex: 0x2A2A2E)
    }

    // MARK: Metrics (radii / spacing / sizes from the CSS)

    enum Metrics {
        // Device frame.
        /// `.iphone{border-radius:52px}`.
        static let deviceCornerRadius: CGFloat = 52
        /// `.iphone{padding:9px}` — bezel thickness.
        static let devicePadding: CGFloat = 9
        /// `box-shadow:0 0 0 1.5px` — chrome-ring width.
        static let deviceRingWidth: CGFloat = 1.5
        /// `.screen{border-radius:44px}`.
        static let screenCornerRadius: CGFloat = 44
        /// `.screen-body{padding:6px 20px 24px}`.
        static let screenBodyPaddingTop: CGFloat = 6
        static let screenBodyPaddingHorizontal: CGFloat = 20
        static let screenBodyPaddingBottom: CGFloat = 24

        // Controls.
        /// `.cta{border-radius:14px}`.
        static let ctaCornerRadius: CGFloat = 14
        /// `.cta{padding:14px 18px}`.
        static let ctaPaddingVertical: CGFloat = 14
        static let ctaPaddingHorizontal: CGFloat = 18
        /// `.cta-row{gap:10px}`.
        static let ctaRowSpacing: CGFloat = 10

        /// `.card{border-radius:16px}`.
        static let cardCornerRadius: CGFloat = 16
        /// `.card{padding:15px}`.
        static let cardPadding: CGFloat = 15
        /// `.list-item{border-radius:14px}`.
        static let listItemCornerRadius: CGFloat = 14
        /// `.list-item{padding:12px 13px}`.
        static let listItemPaddingVertical: CGFloat = 12
        static let listItemPaddingHorizontal: CGFloat = 13
        /// `.field{border-radius:13px}`.
        static let fieldCornerRadius: CGFloat = 13
        /// `.field{padding:14px 15px}`.
        static let fieldPaddingVertical: CGFloat = 14
        static let fieldPaddingHorizontal: CGFloat = 15

        /// `.phase-tag{border-radius:999px}` / `.badge` / `.phone-label`.
        static let pillCornerRadius: CGFloat = 999
        /// `.phase-tag{padding:5px 12px}`.
        static let phaseTagPaddingVertical: CGFloat = 5
        static let phaseTagPaddingHorizontal: CGFloat = 12

        // Bottom dots nav (`.dots-nav`).
        /// `.dots-nav i{width:9px;height:9px}`.
        static let dotSize: CGFloat = 9
        /// `.dots-nav{gap:7px}`.
        static let dotSpacing: CGFloat = 7
        /// `.dots-nav i.on{transform:scale(1.3)}`.
        static let dotActiveScale: CGFloat = 1.3
    }

    // MARK: Fonts
    //
    // The mockup uses the SF Pro / system stack (`--font-sf`). We map each
    // in-screen text rule to a `Font` with the exact px size + weight, using the
    // system font (SwiftUI's default == SF on iOS) so it matches `-apple-system`.

    enum Typography {
        /// `.title-xl{font-size:25px;font-weight:700}` (letter-spacing:-.6px).
        static let titleXL = Font.system(size: 25, weight: .bold)
        static let titleXLTracking: CGFloat = -0.6

        /// `.title-l{font-size:19px;font-weight:650}` (letter-spacing:-.3px).
        static let titleL = Font.system(size: 19, weight: .semibold)
        static let titleLTracking: CGFloat = -0.3

        /// `.body{font-size:13.5px;line-height:1.5}`.
        static let body = Font.system(size: 13.5, weight: .regular)
        static let bodyLineSpacing: CGFloat = 13.5 * 0.5   // 1.5 line-height → ~6.75pt extra

        /// `.body-strong{font-size:15px;font-weight:500}`.
        static let bodyStrong = Font.system(size: 15, weight: .medium)

        /// `.body-xs{font-size:11px;line-height:1.4}`.
        static let bodyXS = Font.system(size: 11, weight: .regular)

        /// `.cta{font-size:15px;font-weight:600}`.
        static let cta = Font.system(size: 15, weight: .semibold)

        /// `.phase-tag{font-size:12px;font-weight:700}` (letter-spacing:.2px).
        static let phaseTag = Font.system(size: 12, weight: .bold)
        static let phaseTagTracking: CGFloat = 0.2

        /// `.phone-label{font-size:11px;font-weight:700;letter-spacing:1.4px}` (uppercase).
        static let phoneLabel = Font.system(size: 11, weight: .bold)
        static let phoneLabelTracking: CGFloat = 1.4

        /// `.counter{font-size:13px;font-variant-numeric:tabular-nums}`.
        static let counter = Font.system(size: 13).monospacedDigit()

        /// `.nav button{font-size:14px;font-weight:600}`.
        static let navButton = Font.system(size: 14, weight: .semibold)
    }

    // MARK: Shadows
    //
    // `--shadow-premium:0 10px 30px -5px rgba(0,0,0,.05),0 4px 12px -2px rgba(0,0,0,.03)`
    // SwiftUI has no spread, so we approximate the dominant ambient layer.

    enum Shadow {
        /// `--shadow-premium` — cards / list rows.
        static let premiumColor = Color.black.opacity(0.05)
        static let premiumRadius: CGFloat = 15
        static let premiumY: CGFloat = 8
    }
}

// MARK: - Per-side accent

/// The two device roles the mockup contrasts: parent (navy `--primary`) vs
/// kid (forest `--secondary`). Drives accent color, label chip, and CTA tint.
enum OnboardingV2Role {
    case parent
    case child

    /// `.phone-label.parent` text "Parent device" / `.phone-label.kid` "Kid · …".
    var label: String { self == .parent ? "PARENT DEVICE" : "KID DEVICE" }

    /// `--primary` for parent, `--secondary` for kid.
    var accent: Color {
        self == .parent ? OnboardingV2Theme.Palette.primary
                        : OnboardingV2Theme.Palette.secondary
    }

    /// `--primary-container` (parent) / `--secondary-container` (kid) — chip bg.
    var accentContainer: Color {
        self == .parent ? OnboardingV2Theme.Palette.primaryContainer
                        : OnboardingV2Theme.Palette.secondaryContainer
    }
}

// MARK: - Text helpers

extension Text {
    /// Applies `.title-xl` (25/700/-.6 tracking).
    func onboardingV2TitleXL() -> some View {
        self.font(OnboardingV2Theme.Typography.titleXL)
            .tracking(OnboardingV2Theme.Typography.titleXLTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }

    /// Applies `.title-l` (19/650/-.3 tracking).
    func onboardingV2TitleL() -> some View {
        self.font(OnboardingV2Theme.Typography.titleL)
            .tracking(OnboardingV2Theme.Typography.titleLTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }

    /// Applies `.body` (13.5/regular, on-surface-variant, 1.5 line-height).
    func onboardingV2Body() -> some View {
        self.font(OnboardingV2Theme.Typography.body)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
            .lineSpacing(OnboardingV2Theme.Typography.bodyLineSpacing)
    }

    /// Applies `.body-strong` (15/medium, on-surface).
    func onboardingV2BodyStrong() -> some View {
        self.font(OnboardingV2Theme.Typography.bodyStrong)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
    }

    /// Applies `.body-xs` (11/regular, on-surface-variant).
    func onboardingV2BodyXS() -> some View {
        self.font(OnboardingV2Theme.Typography.bodyXS)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

// MARK: - Primary CTA  (`.cta` / `.cta.green`)

/// The full-width filled Continue button. `.cta` is navy `--primary`; the kid
/// flow uses `.cta.green` (`--secondary`). Pass `role` (or an explicit `fill`)
/// to choose the tint. Matches: 14×18 padding, 14px radius, 15/600 label.
struct OnboardingV2PrimaryButton: View {
    let title: String
    /// Optional leading SF Symbol (mockup CTAs sometimes carry an icon/glyph).
    var systemImage: String? = nil
    /// Tint. Defaults to navy `--primary`; pass `.secondary` for `.cta.green`.
    var fill: Color = OnboardingV2Theme.Palette.primary
    let action: () -> Void

    init(_ title: String,
         systemImage: String? = nil,
         fill: Color = OnboardingV2Theme.Palette.primary,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.fill = fill
        self.action = action
    }

    /// Convenience: tint from a role (`.parent` → navy, `.child` → green).
    init(_ title: String,
         systemImage: String? = nil,
         role: OnboardingV2Role,
         action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, fill: role.accent, action: action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {           // `.cta{gap:8px}`
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta)
            .foregroundStyle(OnboardingV2Theme.Palette.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, OnboardingV2Theme.Metrics.ctaPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    .fill(fill)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Secondary / back affordance  (`.cta-secondary`)

/// The outlined "ghost" button: transparent fill, 1px `--outline-variant`
/// border, `--primary` label. Same 14×18 / 14px-radius footprint as the primary
/// CTA. Used for "Enter 6-digit code", "Don't Allow", "Skip", "Back", etc.
struct OnboardingV2SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    init(_ title: String,
         systemImage: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(OnboardingV2Theme.Typography.cta)
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, OnboardingV2Theme.Metrics.ctaPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.ctaCornerRadius,
                                 style: .continuous)
                    .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phase tag  (`.phase-tag`)

/// The pill chip showing the flow phase, e.g. "2 · Accounts". Mockup: 5×12
/// padding, 999px radius, 12/700 text, `--primary-container` bg + `--primary` fg.
struct OnboardingV2PhaseTag: View {
    let phase: String

    init(_ phase: String) { self.phase = phase }

    var body: some View {
        Text(phase)
            .font(OnboardingV2Theme.Typography.phaseTag)
            .tracking(OnboardingV2Theme.Typography.phaseTagTracking)
            .foregroundStyle(OnboardingV2Theme.Palette.primary)
            .padding(.vertical, OnboardingV2Theme.Metrics.phaseTagPaddingVertical)
            .padding(.horizontal, OnboardingV2Theme.Metrics.phaseTagPaddingHorizontal)
            .background(
                Capsule().fill(OnboardingV2Theme.Palette.primaryContainer)
            )
    }
}

// MARK: - Step counter  (`.counter`)

/// "Step N of M" — the mockup footer uses a bare "N / M" counter (13px,
/// tabular-nums). We expose both the raw count and a labeled variant.
struct OnboardingV2StepCounter: View {
    let index: Int   // 1-based
    let total: Int
    /// `true` → "Step 3 of 12"; `false` → "3 / 12" (raw mockup style).
    var labeled: Bool = true

    init(index: Int, total: Int, labeled: Bool = true) {
        self.index = index
        self.total = total
        self.labeled = labeled
    }

    var body: some View {
        Text(labeled ? "Step \(index) of \(total)" : "\(index) / \(total)")
            .font(OnboardingV2Theme.Typography.counter)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
    }
}

// MARK: - Bottom dots progress nav  (`.dots-nav`)

/// The row of progress dots. 9×9 `--outline-variant` dots; the active dot is
/// `--primary` scaled 1.3×. Tapping a dot jumps to that step (optional).
struct OnboardingV2DotsNav: View {
    let count: Int
    let current: Int   // 0-based
    var onSelect: ((Int) -> Void)? = nil

    init(count: Int, current: Int, onSelect: ((Int) -> Void)? = nil) {
        self.count = count
        self.current = current
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: OnboardingV2Theme.Metrics.dotSpacing) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == current
                Circle()
                    .fill(on ? OnboardingV2Theme.Palette.primary
                             : OnboardingV2Theme.Palette.outlineVariant)
                    .frame(width: OnboardingV2Theme.Metrics.dotSize,
                           height: OnboardingV2Theme.Metrics.dotSize)
                    .scaleEffect(on ? OnboardingV2Theme.Metrics.dotActiveScale : 1)
                    .animation(.easeInOut(duration: 0.2), value: current)
                    .onTapGesture { onSelect?(i) }
            }
        }
    }
}

// MARK: - Card  (`.card`)

/// The white surface-lowest card: 16px radius, 15px padding, premium shadow.
/// In dark mode (`.iphone.dark .card`) it's `#16161b` with a hairline border.
struct OnboardingV2Card<Content: View>: View {
    var dark: Bool = false
    @ViewBuilder var content: () -> Content

    init(dark: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.dark = dark
        self.content = content
    }

    var body: some View {
        content()
            .padding(OnboardingV2Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                 style: .continuous)
                    .fill(dark ? OnboardingV2Theme.Palette.darkCard
                               : OnboardingV2Theme.Palette.surfaceLowest)
            )
            .overlay(
                dark
                ? RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.cardCornerRadius,
                                   style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                : nil
            )
            .shadow(color: dark ? .clear : OnboardingV2Theme.Shadow.premiumColor,
                    radius: dark ? 0 : OnboardingV2Theme.Shadow.premiumRadius,
                    x: 0,
                    y: dark ? 0 : OnboardingV2Theme.Shadow.premiumY)
    }
}

// MARK: - Phone-screen container  (`.iphone` + `.screen` + `.screen-body`)
//
// The reusable "phone screen" frame every onboarding step renders inside. It
// reproduces the mockup chrome with title / subtitle / content / footer slots:
//
//   ┌──────────────────────────────┐  ← device bezel (#0c0c0e, 52px radius)
//   │ ┌──────────────────────────┐ │
//   │ │  PARENT DEVICE  (label)   │ │  ← role chip
//   │ │  2 · Accounts  Step 3/12  │ │  ← phase tag + counter
//   │ │                           │ │
//   │ │  Title (title-xl)         │ │  ← title slot
//   │ │  Subtitle (body)          │ │  ← subtitle slot
//   │ │                           │ │
//   │ │  …content…                │ │  ← content slot (your screen)
//   │ │                           │ │
//   │ │  [ Continue CTA ]         │ │  ← footer slot (cta-row, pinned bottom)
//   │ │  • • • ● • •  dots         │ │  ← dots nav
//   │ └──────────────────────────┘ │
//   └──────────────────────────────┘
//
// `showsChrome:false` drops the device bezel (e.g. when the host already owns a
// real device frame) and renders just the screen body, so the same container is
// reusable both standalone and embedded.
struct OnboardingV2ScreenContainer<Content: View, Footer: View>: View {

    let role: OnboardingV2Role
    let phase: String
    let stepIndex: Int      // 1-based
    let stepTotal: Int
    let title: String
    var subtitle: String? = nil
    /// Dark screen (`.iphone.dark`) — e.g. the "TikTok is blocked" kid screen.
    var dark: Bool = false
    /// Draw the iPhone bezel + ring. False → bare screen body only.
    var showsDeviceFrame: Bool = false
    /// Optional dots-progress nav under the footer.
    var dotsCount: Int? = nil
    var dotsCurrent: Int? = nil

    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(role: OnboardingV2Role,
         phase: String,
         stepIndex: Int,
         stepTotal: Int,
         title: String,
         subtitle: String? = nil,
         dark: Bool = false,
         showsDeviceFrame: Bool = false,
         dotsCount: Int? = nil,
         dotsCurrent: Int? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.role = role
        self.phase = phase
        self.stepIndex = stepIndex
        self.stepTotal = stepTotal
        self.title = title
        self.subtitle = subtitle
        self.dark = dark
        self.showsDeviceFrame = showsDeviceFrame
        self.dotsCount = dotsCount
        self.dotsCurrent = dotsCurrent
        self.content = content
        self.footer = footer
    }

    private var screenBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {

            // Header: role chip + phase tag + counter.
            VStack(alignment: .leading, spacing: Spacing.lg) {
                roleChip
                HStack(spacing: Spacing.md) {
                    OnboardingV2PhaseTag(phase)
                    Spacer(minLength: 0)
                    OnboardingV2StepCounter(index: stepIndex, total: stepTotal)
                }
            }

            // Title + subtitle slots.
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(title)
                    .onboardingV2TitleL()
                    .foregroundStyle(dark ? Color.white
                                          : OnboardingV2Theme.Palette.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .onboardingV2Body()
                        .foregroundStyle(dark ? OnboardingV2Theme.Palette.darkBody
                                              : OnboardingV2Theme.Palette.onSurfaceVariant)
                }
            }

            // Content slot.
            content()

            Spacer(minLength: Spacing.lg)

            // Footer slot (cta-row, pinned bottom).
            VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                footer()
                if let dotsCount, let dotsCurrent {
                    OnboardingV2DotsNav(count: dotsCount, current: dotsCurrent)
                        .padding(.top, Spacing.sm)
                }
            }
        }
        .padding(.top, OnboardingV2Theme.Metrics.screenBodyPaddingTop)
        .padding(.horizontal, OnboardingV2Theme.Metrics.screenBodyPaddingHorizontal)
        .padding(.bottom, OnboardingV2Theme.Metrics.screenBodyPaddingBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(dark ? OnboardingV2Theme.Palette.darkScreen
                         : OnboardingV2Theme.Palette.surface)
    }

    private var roleChip: some View {
        Text(role.label)
            .font(OnboardingV2Theme.Typography.phoneLabel)
            .tracking(OnboardingV2Theme.Typography.phoneLabelTracking)
            .foregroundStyle(role.accent)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(Capsule().fill(role.accentContainer))
    }

    var body: some View {
        if showsDeviceFrame {
            screenBody
                .clipShape(RoundedRectangle(
                    cornerRadius: OnboardingV2Theme.Metrics.screenCornerRadius,
                    style: .continuous))
                .padding(OnboardingV2Theme.Metrics.devicePadding)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.deviceCornerRadius,
                                     style: .continuous)
                        .fill(OnboardingV2Theme.Palette.deviceBody)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingV2Theme.Metrics.deviceCornerRadius,
                                     style: .continuous)
                        .stroke(OnboardingV2Theme.Palette.deviceRing,
                                lineWidth: OnboardingV2Theme.Metrics.deviceRingWidth)
                )
        } else {
            screenBody
        }
    }
}

// Convenience overload: a screen with no dots nav still needs a footer; this
// keeps the common "frameless, no dots" call site terse.
extension OnboardingV2ScreenContainer {
    /// Frameless screen body (no device bezel) — for embedding in a host that
    /// already supplies a real device frame.
    init(embeddedRole role: OnboardingV2Role,
         phase: String,
         stepIndex: Int,
         stepTotal: Int,
         title: String,
         subtitle: String? = nil,
         dark: Bool = false,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.init(role: role,
                  phase: phase,
                  stepIndex: stepIndex,
                  stepTotal: stepTotal,
                  title: title,
                  subtitle: subtitle,
                  dark: dark,
                  showsDeviceFrame: false,
                  content: content,
                  footer: footer)
    }
}

#if DEBUG
#Preview("Parent screen") {
    OnboardingV2ScreenContainer(
        role: .parent,
        phase: "2 · Accounts",
        stepIndex: 3,
        stepTotal: 12,
        title: "Create your parent account",
        subtitle: "This account owns your family and lets you recover it on a new phone.",
        dotsCount: 12,
        dotsCurrent: 2,
        content: {
            VStack(spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                OnboardingV2Card {
                    Text("Continue with Apple").onboardingV2BodyStrong()
                }
                OnboardingV2Card {
                    Text("Continue with Google").onboardingV2BodyStrong()
                }
            }
        },
        footer: {
            OnboardingV2PrimaryButton("Continue", role: .parent) {}
        }
    )
    .padding()
    .background(OnboardingV2Theme.Palette.surfaceLow)
}

#Preview("Kid screen (green CTA)") {
    OnboardingV2ScreenContainer(
        role: .child,
        phase: "3 · Kid consent",
        stepIndex: 6,
        stepTotal: 11,
        title: "What Evlin can see",
        subtitle: "Here's exactly what that means.",
        content: { Color.clear.frame(height: 80) },
        footer: {
            OnboardingV2PrimaryButton("I understand — continue", role: .child) {}
        }
    )
    .padding()
    .background(OnboardingV2Theme.Palette.surfaceLow)
}
#endif
