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

/// Mockup M[2].parent — "Create your parent account": Apple / Google sign-in
/// buttons + a DEBUG-only dev sign-in for the simulator. Performs the real
/// AuthService flows; on a signed-in session it calls `onSignedIn` to advance.
struct ParentSignInStep: View {
    /// Authed session built once in the coordinator (off the shared APIClient)
    /// and threaded in. Optional only because the coordinator builds it lazily
    /// in `.task`; the buttons guard on it.
    let auth: AuthService?
    let onSignedIn: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var busy = false
    @State private var errorText: String?

    // Held for the duration of an Apple/Google presentation.
    @State private var appleCoordinator = AppleSignInCoordinator()
    @State private var googleCoordinator = GoogleSignInCoordinator()

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
                        action: { Task { await signInWithApple() } }
                    )
                    .disabled(busy)

                    // Google — white fill, dark label, hairline border.
                    Button(action: { Task { await signInWithGoogle() } }) {
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
                    .disabled(busy)

                    #if DEBUG
                    // DEBUG-only: lets the simulator authenticate without a real
                    // Apple/Google id_token. POSTs /auth/dev-signin with a unique
                    // dev email so each run mints a fresh family-less account.
                    OnboardingV2SecondaryButton("Dev sign in (sim)",
                                                systemImage: "ladybug",
                                                action: { Task { await devSignIn() } })
                        .disabled(busy)
                    #endif

                    if busy {
                        HStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…").onboardingV2BodyXS()
                        }
                        .padding(.top, Spacing.sm)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Spacing.sm)
                    }

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
        .onAppear {
            // A returning parent whose Keychain session was restored is already
            // signed in — skip straight ahead.
            if auth?.account != nil { onSignedIn() }
        }
    }

    @MainActor
    private func signInWithApple() async {
        guard let auth else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            let cred = try await appleCoordinator.signIn()
            await auth.signInWithApple(
                identityToken: cred.identityToken,
                authorizationCode: cred.authorizationCode,
                fullName: cred.fullName
            )
            finish(auth)
        } catch AppleSignInCoordinator.AppleSignInError.cancelled {
            // User-cancel is non-fatal: no error banner.
        } catch {
            errorText = "Apple sign-in failed. Try again."
        }
    }

    @MainActor
    private func signInWithGoogle() async {
        guard let auth else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            let cred = try await googleCoordinator.signIn()
            await auth.signInWithGoogle(idToken: cred.idToken, fullName: cred.fullName)
            finish(auth)
        } catch {
            // GoogleSignIn surfaces cancel as an error too; only show a banner
            // when no session resulted.
            if auth.account == nil {
                errorText = "Google sign-in isn't available. Use Apple or Dev sign in."
            } else {
                finish(auth)
            }
        }
    }

    #if DEBUG
    @MainActor
    private func devSignIn() async {
        guard let auth else { return }
        busy = true; errorText = nil
        defer { busy = false }
        let email = "dev+\(UUID().uuidString.prefix(8).lowercased())@evlin.test"
        await auth.signInWithDevEmail(email: email, displayName: "Dev Parent")
        finish(auth)
    }
    #endif

    /// Advance only when AuthService actually has a session; otherwise surface
    /// the last error it recorded.
    @MainActor
    private func finish(_ auth: AuthService) {
        if auth.account != nil {
            onSignedIn()
        } else {
            errorText = auth.lastError.map { "Sign-in failed (\($0))." }
                ?? "Sign-in failed. Try again."
        }
    }
}

// MARK: - 4 · Your profile

/// Mockup M[3].parent — "Tell us about you": avatar + name / birthday fields +
/// gender segmented control. On save we PUT /me/profile (display_name) and, on
/// success, surface the mockup's "Profile saved" state before advancing.
///
/// NOTE on shape: the live `UpdateParentProfileBody` (PUT /me/profile) carries
/// `display_name` + avatar fields only — there is NO parent birth_year/gender on
/// that DTO (those live on the CHILD profile). So the birthday/gender controls
/// stay as visual placeholders; only the entered NAME is persisted.
struct ParentProfileStep: View {
    let apiClient: APIClient
    let onSaved: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var name = "Morgan"
    @State private var genderIndex = 0
    @State private var saved = false
    @State private var busy = false
    @State private var errorText: String?

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

                        OnboardingV2EditableField(label: "NAME", text: $name)
                        OnboardingV2LabeledField(label: "BIRTHDAY", value: "March 14, 1989",
                                                 trailingSystemImage: "calendar")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("GENDER").onboardingV2FieldLabel()
                            OnboardingV2Segmented(options: ["Female", "Male", "Other"],
                                                  selectedIndex: genderIndex)
                        }

                        if let errorText {
                            Text(errorText)
                                .font(OnboardingV2Theme.Typography.bodyXS)
                                .foregroundStyle(OnboardingV2Theme.Palette.error)
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(busy ? "Saving…" : "Continue", role: .parent) {
                    if saved { onSaved() } else { Task { await save() } }
                }
                .disabled(busy)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }

    @MainActor
    private func save() async {
        busy = true; errorText = nil
        defer { busy = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = UpdateParentProfileBody(
            display_name: trimmed.isEmpty ? nil : trimmed,
            avatar_kind: nil,
            avatar_value: nil,
            avatar_color: nil
        )
        do {
            _ = try await apiClient.updateParentProfile(body)
            withAnimation { saved = true }
        } catch {
            errorText = "Couldn't save your profile. Tap Continue to retry."
        }
    }
}

// MARK: - 5 · New or join

/// Mockup M[4].parent — "Welcome": two choice cards — start a new family
/// (the kid creates the family; the parent pairs next) vs join an existing one
/// by entering a co-parent invite code. "Start a new family" just advances to
/// pairing; "Join" POSTs /family/invite/consume with the entered code (if any),
/// then also advances to pairing.
struct ParentNewOrJoinStep: View {
    let apiClient: APIClient
    let onStartNew: () -> Void
    /// Plan 5: hands the entered co-parent invite code UP to the coordinator,
    /// which owns the POST /family/invite/consume + the pending-approval routing
    /// (→ parentCoParentJoin). Returns `nil` on a clean handoff or an inline
    /// error string to show. Empty code is rejected here (a co-parent join
    /// requires a code; an empty "join" no longer silently lands on pairing).
    let onJoinCode: (String) async -> String?
    var onBack: (() -> Void)? = nil

    @State private var startNew = true
    @State private var inviteCode = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "Set up your family",
            subtitle: "Start fresh, or join one a co-parent already made.",
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
                        title: "Join an existing family",
                        subtitle: "Enter a co-parent invite code",
                        selected: !startNew,
                        role: .parent
                    ) { startNew = false }

                    if !startNew {
                        OnboardingV2EditableField(label: "INVITE CODE", text: $inviteCode)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton(
                    startNew ? "Start a new family" : (busy ? "Joining…" : "Join family"),
                    role: .parent
                ) {
                    if startNew { onStartNew() } else { Task { await join() } }
                }
                .disabled(busy)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }

    @MainActor
    private func join() async {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorText = "Enter the invite code your co-parent shared with you."
            return
        }
        busy = true; errorText = nil
        defer { busy = false }
        // The coordinator owns the consume + pending-approval routing (Plan 5).
        if let err = await onJoinCode(code.uppercased()) {
            errorText = err
        }
    }
}

// MARK: - 6 · Scan to pair

/// Mockup M[5].parent — "Scan the kid's code": a camera scan frame (placeholder)
/// + the REAL 6-digit-code entry. On submit it calls `onPaired(code)` which runs
/// POST /family/pair in the coordinator; on success (observed via
/// `pairedSucceeded`) it advances to "Connected". On a 4xx the returned error
/// is shown inline.
struct ParentPairScanStep: View {
    /// Submits the typed code; returns `nil` on success or an error string. The
    /// real /family/pair call lives in the coordinator.
    let onPaired: (String) async -> String?
    /// True once the coordinator recorded a successful pair (familyID bound).
    let pairedSucceeded: Bool
    /// Advance to the connected screen (called after a successful pair).
    let onAdvance: () -> Void
    var onEnterCodeInstead: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 6,
            stepTotal: parentTotal,
            title: "Scan the kid's code",
            subtitle: "Point your camera at the QR on your kid's phone — or type the 6-digit code it shows.",
            dotsCount: parentTotal,
            dotsCurrent: 5,
            content: {
                VStack(spacing: Spacing.lg) {
                    OnboardingV2ScanFrame()
                        .frame(maxWidth: .infinity)

                    // The REAL path: type the kid's 6-digit code.
                    OnboardingV2CodeField(code: $code)
                        .onChange(of: code) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue { code = digits }
                            if digits.count > 6 { code = String(digits.prefix(6)) }
                            errorText = nil
                            if code.count == 6 && !busy { Task { await submit() } }
                        }

                    if busy {
                        HStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text("Pairing…").onboardingV2BodyXS()
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.center)
                    }

                    OnboardingV2PrimaryButton(busy ? "Pairing…" : "Pair", role: .parent) {
                        Task { await submit() }
                    }
                    .disabled(busy || code.count != 6)
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
        .onChange(of: pairedSucceeded) { _, ok in
            if ok { onAdvance() }
        }
    }

    @MainActor
    private func submit() async {
        guard !busy, code.count == 6 else { return }
        busy = true; errorText = nil
        defer { busy = false }
        if let err = await onPaired(code) {
            errorText = err
        } else {
            onAdvance()
        }
    }
}

// MARK: - 7 · Connected (parent)

/// Mockup M[6].parent — "Connected to <kid>": big green check, then wait while
/// the kid grants permissions. `kidName` comes from the pair response →
/// FamilyStore resolution threaded through the coordinator.
struct ParentConnectedStep: View {
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    /// Trimmed display name with a neutral fallback so the copy never reads
    /// "Connected to ." before the FamilyStore projection lands.
    private var name: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

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
                    Text("Connected to \(name)").onboardingV2TitleL()
                    Text("Now \(name) grants a few permissions on their phone. We'll wait.")
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
/// Evlin confirms) + an APP→BLOCK explainer card. The LIVE end-to-end test
/// (Plan 7, §8): tapping "Send block" fires a REAL all-apps reflection lock on
/// the kid DEVICE (with the §14.1 short cap so it can never brick the kid for
/// 2h), then polls /parent/state/{child} for the honest `lock_applied_at` ack —
/// the kid's phone confirming it actually applied the lock — before advancing
/// to the "It works" payoff. Visuals unchanged; the button now does the real call.
struct ParentFirstActionsStep: View {
    /// Live backend client + the threaded child DEVICE id (§1.1) the lock keys
    /// on. `familyID` is currently unused by the reflection trigger (it is
    /// state-derived/kid-scoped) but threaded for forward-compat with the
    /// catalog app-block path. `kidName` drives the honest copy.
    let apiClient: APIClient
    let familyID: UUID?
    let childDeviceID: UUID?
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var phase: FirstActionPhase = .idle
    @State private var reflectionID: UUID?
    @State private var pollTask: Task<Void, Never>?

    /// ≤30s payoff budget — short enough to keep onboarding snappy, long enough
    /// for a healthy kid device's 20s state poll to apply + post lock-applied.
    private static let payoffBudgetSeconds = 30

    private var kid: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Liam" : t
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 10,
            stepTotal: parentTotal,
            title: "Send your first block",
            subtitle: FirstActionsLogic.payoffSubtitle(phase: phase, kidName: kid),
            dotsCount: parentTotal,
            dotsCurrent: 9,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                        OnboardingV2ChatBubble(.me, text: "Block distracting apps for a few minutes")
                        OnboardingV2ChatBubble(
                            .evlin,
                            attributed: {
                                var s = AttributedString("Sending a quick test lock.")
                                s.font = OnboardingV2Theme.Typography.bodyStrong
                                var t = AttributedString(
                                    "\nIt'll lock \(kid)'s apps briefly — watch their screen to confirm it landed.")
                                t.font = OnboardingV2Theme.Typography.body
                                return s + t
                            }()
                        )
                    }

                    OnboardingV2Card {
                        HStack(alignment: .top, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                            OnboardingV2Badge(badgeText, style: phase == .landed ? .success : .new)
                            Text(cardText)
                                .onboardingV2BodyXS()
                        }
                    }

                    if phase == .waitingForKid || phase == .sending {
                        HStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text(phase == .sending ? "Sending…" : "Waiting for \(kid)'s phone…")
                                .onboardingV2BodyXS()
                        }
                    }
                }
            },
            footer: {
                switch phase {
                case .landed:
                    OnboardingV2PrimaryButton("It works — continue", role: .parent, action: onContinue)
                case .timedOut, .failed:
                    OnboardingV2PrimaryButton("Try again", systemImage: "paperplane.fill",
                                              role: .parent) { Task { await sendBlock() } }
                    OnboardingV2SecondaryButton("Skip for now", action: onContinue)
                default:
                    OnboardingV2PrimaryButton(
                        phase == .idle ? "Send block" : "Sending…",
                        systemImage: "paperplane.fill",
                        role: .parent
                    ) { Task { await sendBlock() } }
                    .disabled(phase == .sending || phase == .waitingForKid)
                }
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .onDisappear { cancelTestLock() }
    }

    private var badgeText: String {
        switch phase {
        case .landed:   return "APPLIED ✓"
        case .timedOut: return "QUEUED"
        case .failed:   return "FAILED"
        default:        return "TEST LOCK"
        }
    }

    private var cardText: String {
        switch phase {
        case .landed:
            return "\(kid)'s phone applied the lock and reported back. This is exactly how a real block works."
        case .timedOut:
            return "The lock is queued and will apply the next time \(kid)'s phone checks in (every ~20s). It auto-releases shortly so it can't get stuck."
        case .failed:
            return "Couldn't reach the backend to send the test lock. Check your connection and try again."
        default:
            return "This sends a REAL short lock to \(kid)'s phone. It auto-releases in a few minutes, so a missed exit can never strand them."
        }
    }

    /// Fire the real test lock + poll for the honest payoff (§8 / §14.1).
    @MainActor
    private func sendBlock() async {
        guard let childDeviceID else {
            // No paired kid device threaded — can't run the live test; let the
            // parent move on rather than stranding them.
            onContinue()
            return
        }
        phase = .sending
        do {
            // Trigger the all-apps reflection lock with the §14.1 short cap. The
            // kid device applies it on its next /child/state poll and posts
            // /child/reflection/{rid}/lock-applied; the backend stamps
            // lock_applied_at, which we poll for below.
            let rid = try await apiClient.triggerOnboardingReflection(
                childDeviceID: childDeviceID,
                reason: "First-actions test lock",
                onboardingCapSeconds: 180
            )
            reflectionID = rid
            phase = .waitingForKid
            startPayoffPoll(childDeviceID: childDeviceID)
        } catch {
            phase = .failed
        }
    }

    /// Poll /parent/state/{child} until the kid's phone reports it APPLIED the
    /// lock (`reflectionRequest.lockAppliedAt != nil`) or the ≤30s budget runs
    /// out (→ honest "queued" copy, never a fake checkmark).
    private func startPayoffPoll(childDeviceID: UUID) {
        pollTask?.cancel()
        let rid = reflectionID
        pollTask = Task { @MainActor in
            var waited = 0
            while !Task.isCancelled && waited < Self.payoffBudgetSeconds {
                if let state = try? await apiClient.fetchParentChildState(childDeviceID: childDeviceID),
                   let req = state.reflectionRequest,
                   (rid == nil || req.id == rid),
                   req.lockAppliedAt != nil {
                    phase = .landed
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                waited += 3
            }
            if !Task.isCancelled { phase = .timedOut }
        }
    }

    /// §14.1 safety: cancel the in-flight test reflection if the parent leaves
    /// the screen before it pays off, so a half-finished test never lingers.
    /// (The short cap is the backstop; this is the immediate cleanup.)
    private func cancelTestLock() {
        pollTask?.cancel()
        pollTask = nil
        if let rid = reflectionID, phase != .landed {
            Task { try? await apiClient.cancelChildReflection(reflectionId: rid) }
        }
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
/// Internal (not file-private) so the co-parent/recovery + first-actions v2
/// screens in sibling files can reuse the same chrome.
struct OnboardingV2BackLink: View {
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

/// Editable variant of `.field` — same surface-container row chrome as
/// `OnboardingV2LabeledField`, but holds a live `TextField` binding so the
/// parent's entered NAME / invite code is captured for the real save/join call.
private struct OnboardingV2EditableField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).onboardingV2FieldLabel()
            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                .tint(OnboardingV2Theme.Palette.primary)
                .autocorrectionDisabled()
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

/// The big monospaced 6-digit pairing-code entry (number pad). Mirrors the
/// legacy PairingCodeStep field but themed for the v2 surface.
private struct OnboardingV2CodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("------", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(size: 34, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .tracking(6)
            .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
            .tint(OnboardingV2Theme.Palette.primary)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity)
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
/// Internal so sibling v2 step files (co-parent/recovery, first-actions) reuse it.
struct OnboardingV2SuccessCheck: View {
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
/// Internal so sibling v2 step files (co-parent/recovery) reuse it.
struct OnboardingV2WaitingSpinner: View {
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
