import SwiftUI
import UserNotifications

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

/// `.field` chrome (surface-container box, 13px radius, 1px border) wrapping an
/// arbitrary control — used by the birth-year menu row so the dropdown matches
/// the static `.field` rows visually.
private struct OnboardingV2ChildFieldBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
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

/// Editable `.field` — same chrome as `OnboardingV2Field` but holds a live
/// `TextField` binding so the kid's NAME is captured for /family/create.
private struct OnboardingV2ChildTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        OnboardingV2ChildFieldBox {
            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                .tint(OnboardingV2Theme.Palette.primary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
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
private struct ChildOnboardingV2BackLink: View {
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
    /// Captured LOCALLY (the kid's family doesn't exist until the next screen).
    /// Threaded into coordinator state, persisted, and read by the parent's
    /// authoritative child write once paired.
    @Binding var name: String
    @Binding var birthYear: Int?
    @Binding var gender: String?
    @Binding var pickedAvatar: UIImage?  // owned by coordinator → uploaded after /family/create
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    // Canonical gender keys persisted on the wire (CreateChildBody.gender). The
    // segmented control shows the human label; the value stored is the key.
    private let genderOptions: [(label: String, key: String)] =
        [("Female", "female"), ("Male", "male"), ("Other", "other")]

    /// I2: collect a full BIRTHDAY (date) instead of just a year. Bounds = a
    /// sensible kid range (4–17 y/o). We derive birthYear from the picked date,
    /// so the backend wire (child_birth_year) is unchanged.
    @State private var birthday = Calendar.current.date(byAdding: .year, value: -10, to: Date()) ?? Date()
    private var birthdayRange: ClosedRange<Date> {
        let now = Date(), cal = Calendar.current
        let oldest = cal.date(byAdding: .year, value: -17, to: now) ?? now
        let youngest = cal.date(byAdding: .year, value: -4, to: now) ?? now
        return oldest...youngest
    }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                    // I1: real tappable photo picker (camera / library); initials
                    // fallback via the Home EvlinAvatarView — no emoji placeholder.
                    OnboardingV2PhotoAvatarPicker(name: name, pickedImage: $pickedAvatar, accent: kidGreen)
                        .padding(.bottom, 1)

                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "NAME")
                        OnboardingV2ChildTextField(placeholder: "Your name", text: $name)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "BIRTHDAY")
                        OnboardingV2ChildFieldBox {
                            HStack {
                                DatePicker("", selection: $birthday, in: birthdayRange,
                                           displayedComponents: .date)
                                    .labelsHidden()
                                    .onChange(of: birthday, initial: true) { _, d in
                                        birthYear = Calendar.current.component(.year, from: d)
                                    }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        OnboardingV2FieldLabel(text: "GENDER")
                        HStack(spacing: 8) {
                            ForEach(genderOptions, id: \.key) { opt in
                                Button {
                                    gender = opt.key
                                } label: {
                                    OnboardingV2Segment(title: opt.label, selected: gender == opt.key)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                OnboardingV2PrimaryButton("Continue", role: .child, action: onContinue)
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.5)
                if let onBack { ChildOnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 5/6 · Show code (kid)  ·  mockup: "Show this to your parent"

struct ChildShowCodeStep: View {
    @EnvironmentObject var apiClient: APIClient

    /// Mints the family (POST /family/create) and threads code + child_device_id
    /// into coordinator state. Returns nil on success or an error string. Run on
    /// appear; the coordinator short-circuits if a code is already minted.
    let createFamily: () async -> String?
    /// The real 6-digit code from the coordinator (empty until create lands).
    let pairingCode: String
    /// Advance to the "linked" screen once a parent consumes the code.
    let onConnected: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var creating = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    /// "4 8 2 9 1 0" — space-separated for the big code readout.
    private var spacedCode: String {
        pairingCode.map(String.init).joined(separator: " ")
    }

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
                    // QR card — a real, scannable QR encoding the pairing code.
                    OnboardingV2Card {
                        HStack {
                            Spacer(minLength: 0)
                            if pairingCode.isEmpty {
                                OnboardingV2FauxQR() // shimmer while the code mints
                            } else {
                                OnboardingV2QRImage(
                                    string: OnboardingV2PairPayload.encode(code: pairingCode))
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    // "Or type this code" card — shows the REAL minted code.
                    OnboardingV2Card {
                        VStack(spacing: 4) {
                            Text("OR TYPE THIS CODE")
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .tracking(1)
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                            if pairingCode.isEmpty {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                            } else {
                                Text(spacedCode)
                                    .font(.system(size: 24, weight: .bold))
                                    .tracking(5)
                                    .foregroundStyle(OnboardingV2Theme.Palette.primary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    if let errorText {
                        VStack(spacing: 6) {
                            Text(errorText)
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .foregroundStyle(OnboardingV2Theme.Palette.error)
                                .multilineTextAlignment(.center)
                            Button("Retry") { Task { await start() } }
                                .font(OnboardingV2Theme.Typography.navButton)
                                .foregroundStyle(OnboardingV2Theme.Palette.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    } else {
                        // Live "waiting for parent to scan" pulse cue.
                        HStack(spacing: 8) {
                            Circle()
                                .fill(OnboardingV2Theme.Palette.tertiary)
                                .frame(width: 8, height: 8)
                            Text(pairingCode.isEmpty ? "Generating your code…"
                                                     : "Waiting for parent to scan…")
                                .onboardingV2Body()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            },
            footer: {
                if let onBack { ChildOnboardingV2BackLink(action: onBack) }
            }
        )
        .task { await start() }
        // Poll with the FRESH code the moment it lands in coordinator state.
        // (The old code called startPolling() from start() on the stale view
        // snapshot, where `pairingCode` was still empty, so the loop exited
        // immediately and the kid never auto-advanced after the parent scanned.)
        .onChange(of: pairingCode, initial: true) { _, code in
            guard !code.isEmpty else { return }
            startPolling(code: code)
        }
        .onDisappear { pollTask?.cancel() }
    }

    /// Create the family (if not already), then begin polling pairing-status.
    @MainActor
    private func start() async {
        guard !creating else { return }
        creating = true
        errorText = nil
        if let err = await createFamily() {
            errorText = err
            creating = false
            return
        }
        creating = false
        // Polling starts via .onChange(of: pairingCode) once the real code lands.
    }

    /// Poll GET /family/pairing-status?code= every 2s; advance once a parent
    /// consumes the code (used == true). Cancels on disappear.
    private func startPolling(code: String) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let status = try? await apiClient.fetchPairingStatus(code: code),
                   status.used {
                    onConnected()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
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
                if let onBack { ChildOnboardingV2BackLink(action: onBack) }
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
                if let onBack { ChildOnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 10 · Allow notifications  ·  mockup: "Stay in the loop"

struct ChildAllowNotificationsStep: View {
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var requesting = false

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
                        OnboardingV2PrimaryButton("Allow", role: .child) {
                            Task { await requestThenAdvance() }
                        }
                        .disabled(requesting)
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
                if let onBack { ChildOnboardingV2BackLink(action: onBack) }
            }
        )
    }

    /// Fire the REAL system notification-permission prompt, then advance
    /// regardless of the outcome (declining is a valid choice — never block the
    /// flow on it). Errors are swallowed: the prompt is best-effort here.
    @MainActor
    private func requestThenAdvance() async {
        requesting = true
        defer { requesting = false }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        onContinue()
    }
}

// MARK: - 12 · Choose what to lock (lockable hub)
//   mockup: "Choose what Evlin can lock"

struct ChildLockableHubStep: View {
    @EnvironmentObject var apiClient: APIClient
    /// The kid's OWN device id (set after /family/create). Apps are made lockable
    /// against it; guarded in the sheet if create hasn't landed yet.
    var familyID: UUID? = nil
    var childDeviceID: UUID? = nil
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        if let familyID, let childDeviceID {
            LockListManagerView(
                familyID: familyID,
                childDeviceID: childDeviceID,
                mode: .onboarding,
                onCompleted: onContinue
            )
            .environmentObject(apiClient)
            .safeAreaInset(edge: .top) {
                if let onBack {
                    ChildOnboardingV2BackLink(action: onBack)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .background(Color.evSurface)
                }
            }
        } else {
            OnboardingV2ScreenContainer(
                embeddedRole: .child,
                phase: "4 · Lockable",
                stepIndex: 10,
                stepTotal: childTotal,
                title: "Choose what Evlin can lock",
                subtitle: "Evlin is still pairing this device.",
                content: {
                    VStack(spacing: 12) {
                        Text("Evlin is still pairing this device.")
                            .font(.headline)
                        Text("Go back and scan the pairing code again if this message does not clear.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                },
                footer: {
                    if let onBack { ChildOnboardingV2BackLink(action: onBack) }
                }
            )
        }
    }
}
