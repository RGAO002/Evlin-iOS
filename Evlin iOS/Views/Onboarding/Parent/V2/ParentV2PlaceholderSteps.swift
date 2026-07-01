import SwiftUI
import UIKit

// Onboarding v2 — PARENT-side screens (spec §7.1).
//
// Real SwiftUI translations of the parent device screens in the v2 mockup
//   docs/superpowers/specs/2026-06-03-onboarding-flow-v2-mockup.html
// Every screen consumes ONLY the tokens + chrome from `OnboardingV2Theme.swift`
// so it stays pixel-aligned with the prototype. Data is intentionally MOCK
// (sample name "Morgan", kid "Liam", code "4 8 2 9 1 0", a fake QR/scan box) —
// the wiring lives in the coordinator, which passes the onContinue / onBack
// closures these views call.
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
    @State private var email = ""
    @State private var password = ""
    @State private var showEmailForm = false

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

                    // Email + password — replaces the old dev-signin escape hatch.
                    if showEmailForm {
                        VStack(spacing: Spacing.sm) {
                            TextField("Email", text: $email)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1))
                            SecureField("Password (8+ characters)", text: $password)
                                .textContentType(.password)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(OnboardingV2Theme.Palette.outlineVariant, lineWidth: 1))
                            OnboardingV2PrimaryButton("Continue with email", role: .parent) {
                                Task { await signInWithEmail() }
                            }
                            .disabled(busy || email.isEmpty || password.count < 8)
                        }
                    } else {
                        // Email sign-in is temporarily disabled — button kept visible
                        // but greyed/non-tappable while Apple/Google are being wired up.
                        // (The form branch above stays compiled for easy re-enable.)
                        OnboardingV2SecondaryButton("Sign in with email",
                                                    systemImage: "envelope",
                                                    action: {})
                            .disabled(true)
                    }

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
        // Deliberately NO auto-skip on a restored Keychain session. The sign-in
        // screen must ALWAYS be shown so the parent re-picks a method (Apple /
        // Google) every time. A silently-restored session was skipping this
        // screen and could leave the rest of the flow on a stale session.
    }

    @MainActor
    private func signInWithApple() async {
        guard let auth else { errorText = "Auth isn't ready yet — try again in a moment."; return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            let cred = try await appleCoordinator.signIn()
            await auth.signInWithApple(
                identityToken: cred.identityToken,
                authorizationCode: cred.authorizationCode,
                fullName: cred.fullName,
                rawNonce: cred.rawNonce
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
        guard let auth else { errorText = "Auth isn't ready yet — try again in a moment."; return }
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
                errorText = "Google sign-in isn't available. Use Apple or email."
            } else {
                finish(auth)
            }
        }
    }

    @MainActor
    private func signInWithEmail() async {
        guard let auth else { errorText = "Auth isn't ready yet — try again in a moment."; return }
        busy = true; errorText = nil
        defer { busy = false }
        await auth.signInWithEmail(
            email: email.trimmingCharacters(in: .whitespaces).lowercased(),
            password: password
        )
        finish(auth)
    }

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

/// Mockup M[3].parent — "Tell us about you": avatar + name. On save we PUT
/// /me/profile (display_name) and, on
/// success, surface the mockup's "Profile saved" state before advancing.
///
/// NOTE on shape: the live `UpdateParentProfileBody` (PUT /me/profile) carries
/// `display_name` + avatar fields only. Birthday/gender are shown as display-only
/// inputs (restored per request); only NAME + avatar persist to the backend today.
struct ParentProfileStep: View {
    let apiClient: APIClient
    let onSaved: () -> Void
    var onBack: (() -> Void)? = nil

    @AppStorage("parentName") private var storedParentName: String = ""
    @State private var name = ""
    @State private var genderIndex = 0
    @State private var parentBirthday = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var saved = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var pickedAvatar: UIImage?  // I1: local-only; backend upload deferred

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
                        OnboardingV2PhotoAvatarPicker(name: name, pickedImage: $pickedAvatar)
                            .frame(maxWidth: .infinity)

                        OnboardingV2EditableField(label: "NAME", text: $name)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("BIRTHDAY").onboardingV2FieldLabel()
                            HStack {
                                DatePicker("", selection: $parentBirthday, in: ...Date(),
                                           displayedComponents: .date)
                                    .labelsHidden()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(OnboardingV2Theme.Palette.surfaceContainer))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("GENDER").onboardingV2FieldLabel()
                            OnboardingV2Segmented(options: ["Female", "Male", "Other"],
                                                  selectedIndex: $genderIndex)
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
        .onAppear {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = storedParentName
            }
        }
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
            if !trimmed.isEmpty {
                storedParentName = trimmed
            }
            // Upload the picked avatar photo (best-effort; initials fallback covers failure).
            if let img = pickedAvatar, let data = evlinAvatarJPEG(img) {
                try? await apiClient.uploadParentAvatar(jpegData: data)
            }
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
                    HStack {
                        Spacer(minLength: 0)
                        OnboardingV2QRScanner(onScan: { scanned in
                            // Pull the 6-digit code out and feed it into the SAME
                            // path the typed field uses: setting `code` triggers
                            // the code-field onChange → submit().
                            if let scannedCode = OnboardingV2PairPayload.code(from: scanned) {
                                code = scannedCode
                            }
                        })
                        Spacer(minLength: 0)
                    }
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
                // P2: the "Enter 6-digit code instead" affordance is gone — it
                // routed to the legacy unauthed PairingCodeStep (always 401s on
                // a v2 authed account, with no Back). The typed-code entry
                // above IS the 6-digit path.
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
    @State private var advancedToWait = false

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
                OnboardingV2WaitingPill("Waiting for kid setup…")
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .task {
            guard !advancedToWait else { return }
            advancedToWait = true
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            onContinue()
        }
    }
}

// MARK: - 8 · Waiting for kid

/// P3: a REAL cross-device wait — polls GET /family/onboarding/child-readiness
/// and auto-advances only when the kid has granted Screen Time AND configured a
/// lockable app (ready_for_first_block). No more fake "Simulate kid ready".
struct ParentWaitingForKidStep: View {
    let apiClient: APIClient
    let childDeviceID: UUID?
    var kidName: String = ""
    /// Fires once the kid is ready; carries the resolved first-block app target.
    let onReady: (ChildReadinessDTO) -> Void
    /// Safety valve: the parent can finish setup even if the kid skips adding a
    /// lockable app (otherwise they wait forever — they can block from Home later).
    var onSkip: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    @State private var status: ChildReadinessDTO?
    @State private var pollTask: Task<Void, Never>?

    private var name: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
    }

    private var waitingSubtitle: String {
        guard let s = status else { return "Complete the steps on \(name)'s phone to continue." }
        if !s.screen_time_granted { return "Waiting for \(name) to allow Screen Time…" }
        if s.lockable_app_count == 0 { return "Waiting for \(name) to pick an app Evlin can lock…" }
        return "Ready!"
    }

    private func waitRow(_ done: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? OnboardingV2Theme.Palette.secondary
                                      : OnboardingV2Theme.Palette.outline)
            Text(text).onboardingV2BodyXS()
        }
    }

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
                VStack(spacing: Spacing.lg) {
                    OnboardingV2WaitingSpinner(name: name, subtitle: waitingSubtitle)
                    if let s = status {
                        VStack(alignment: .leading, spacing: 8) {
                            waitRow(s.screen_time_granted, "Allowed Screen Time")
                            waitRow(s.lockable_app_count > 0, "Picked an app Evlin can lock")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                // No "Skip" — the parent auto-advances once the kid is ready
                // (kid is required to pick a lockable app, so readiness lands).
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        guard let id = childDeviceID else { return }
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let r = try? await apiClient.fetchChildReadiness(childDeviceID: id) {
                    status = r
                    // Gate ONLY on the kid's explicit "All set!" signal (the kid posts it
                    // when it reaches the All-set screen — AFTER granting Screen Time,
                    // picking apps, and setting the safety passcode). Deliberately NOT the
                    // looser readiness booleans: on a REUSED kid device those are already
                    // true from a prior run, which would end the parent's wait before the
                    // kid finishes this round. The backend resets `all_set` when the kid
                    // starts a fresh onboarding (POST /family/create), so this is per-run.
                    if r.all_set ?? false {
                        onReady(r)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

// MARK: - 9 · Tamper passcode

/// Mockup M[14].parent — "One safety lock": 3 numbered steps to set an iOS
/// Screen Time passcode, then deep-link out / confirm.
struct ParentSetPasscodeV2Step: View {
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil
    // Reusable on the KID chain too: the Screen Time passcode is set ON the kid's
    // phone (it's what stops the kid turning Evlin off), so this screen now also
    // appears in the kid flow with kid theming/copy. Defaults keep the legacy
    // parent-side call sites compiling unchanged.
    var role: OnboardingV2Role = .parent
    var phase: String = "5 · Parent finish"
    var stepIndex: Int = 9
    var dotsCurrent: Int = 8
    var total: Int = parentTotal

    private var kid: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    private var subtitleText: String {
        role == .child
            ? "Set a Screen Time passcode on this phone — it stops Evlin from being turned off."
            : "Set a Screen Time passcode \(kid) doesn't know — it stops them turning Evlin off."
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: role,
            phase: phase,
            stepIndex: stepIndex,
            stepTotal: total,
            title: "One safety lock",
            subtitle: subtitleText,
            dotsCount: total,
            dotsCurrent: dotsCurrent,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    OnboardingV2NumberedStep(number: 1, text: "Open Settings → Screen Time")
                    OnboardingV2NumberedStep(number: 2, text: "Tap \u{201C}Lock Screen Time Settings\u{201D}")
                    OnboardingV2NumberedStep(number: 3, text: "Pick a 4-digit code \(kid) won't guess")
                }
            },
            footer: {
                // P1: the primary deep-links OUT to Settings and does NOT
                // advance the step — only "I've set it" continues the chain.
                OnboardingV2PrimaryButton("Open Screen Time settings", role: role,
                                          action: openScreenTimeSettings)
                OnboardingV2SecondaryButton("I've set it", action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }

    /// Best-effort deep link to Settings → Screen Time. Mirrors the existing
    /// fallback-chain pattern in `CreateChildAppleIDStep.openFamilySettings`:
    /// App-Prefs paths are not API-stable, so fall down the chain to plain
    /// Settings (`openSettingsURLString`) when a candidate doesn't parse.
    private func openScreenTimeSettings() {
        let candidates = [
            "App-prefs:root=SCREEN_TIME",
            "App-Prefs:root=SCREEN_TIME",
            "App-Prefs:",
            UIApplication.openSettingsURLString,
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            UIApplication.shared.open(url)
            return
        }
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
    /// P2: the exact app (from the kid's lockable catalog, resolved by the
    /// readiness poll) this first block targets — so "Send block" blocks ONE
    /// real app, not an all-apps reflection.
    var firstBlockApp: ChildReadinessDTO.App? = nil
    /// P5: carries whether the kid's phone CONFIRMED the lock applied
    /// (`true` only from the .landed payoff; `false` from "Skip for now" after
    /// a timeout/failure) so the next screen never claims "it landed" when it
    /// didn't.
    let onContinue: (_ landed: Bool) -> Void
    var onBack: (() -> Void)? = nil
    /// Single Device Mode: the kid CommandPoller is stopped while this device is in parent mode,
    /// so the inline ≤30s ack-poll can only ever time out. Under this flag we skip the dead-wait
    /// and tell the tester to switch to the K side to watch the (already-queued) lock apply.
    var singleDevice: Bool = false

    @State private var phase: FirstActionPhase = .idle
    @State private var blockCommandID: UUID?
    @State private var pollTask: Task<Void, Never>?

    private var blockAppName: String { firstBlockApp?.display_name ?? "a distracting app" }
    private var hasResolvedFirstBlockTarget: Bool { firstBlockApp != nil }

    /// ≤30s payoff budget — short enough to keep onboarding snappy, long enough
    /// for a healthy kid device's 20s state poll to apply + post lock-applied.
    private static let payoffBudgetSeconds = 30

    private var kid: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 10,
            stepTotal: parentTotal,
            title: "Send your first block",
            subtitle: (singleDevice && phase == .timedOut)
                ? "Sent! Tap the K button to become \(kid) and watch \(blockAppName) lock — then tap P to come back and continue."
                : FirstActionsLogic.payoffSubtitle(phase: phase, kidName: kid),
            dotsCount: parentTotal,
            dotsCurrent: 9,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if hasResolvedFirstBlockTarget {
                        VStack(alignment: .leading, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                            OnboardingV2ChatBubble(.me, text: "Block \(blockAppName) for a few minutes")
                            OnboardingV2ChatBubble(
                                .evlin,
                                attributed: {
                                    var s = AttributedString("Sending a quick test block.")
                                    s.font = OnboardingV2Theme.Typography.bodyStrong
                                    var t = AttributedString(
                                        "\nIt'll block \(blockAppName) on \(kid)'s phone briefly — watch their screen to confirm it landed.")
                                    t.font = OnboardingV2Theme.Typography.body
                                    return s + t
                                }()
                            )
                        }
                    } else {
                        OnboardingV2Card {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("Waiting for kid setup")
                                    .font(OnboardingV2Theme.Typography.bodyStrong)
                                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                                Text("\(kid)'s phone still needs Screen Time access and one lockable app before you can send the first block.")
                                    .onboardingV2BodyXS()
                            }
                        }
                    }

                    if hasResolvedFirstBlockTarget {
                        OnboardingV2Card {
                            HStack(alignment: .top, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                                OnboardingV2Badge(badgeText, style: phase == .landed ? .success : .new)
                                Text(cardText)
                                    .onboardingV2BodyXS()
                            }
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
                if hasResolvedFirstBlockTarget {
                    switch phase {
                    case .landed:
                        OnboardingV2PrimaryButton("It works — continue", role: .parent) {
                            onContinue(true)
                        }
                    case .timedOut, .failed:
                        OnboardingV2PrimaryButton("Try again", systemImage: "paperplane.fill",
                                                  role: .parent) { Task { await sendBlock() } }
                        OnboardingV2SecondaryButton("Skip for now") { onContinue(false) }
                    default:
                        OnboardingV2PrimaryButton(
                            phase == .idle ? "Send block" : "Sending…",
                            systemImage: "paperplane.fill",
                            role: .parent
                        ) { Task { await sendBlock() } }
                        .disabled(phase == .sending || phase == .waitingForKid)
                    }
                } else {
                    // Escape hatch: the kid's phone may never report a lockable
                    // app (incomplete kid setup, single-device testing), leaving
                    // this screen with no forward path. Let the parent advance
                    // manually — onContinue(false) means "no confirmed block",
                    // same honest signal the timeout/fail path sends.
                    OnboardingV2PrimaryButton("Skip for now", role: .parent) { onContinue(false) }
                    OnboardingV2SecondaryButton("Back to waiting", action: onBack ?? {})
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
            return "This blocks \(blockAppName) on \(kid)'s phone for a few minutes. It auto-releases, so a missed exit can never strand them."
        }
    }

    /// Fire the real test lock + poll for the honest payoff (§8 / §14.1).
    @MainActor
    private func sendBlock() async {
        guard let childDeviceID, let familyID, let app = firstBlockApp else {
            // The readiness gate requires a configured app, so this shouldn't
            // happen. Keep the parent on this screen with an honest failure
            // instead of advancing to the payoff.
            phase = .failed
            return
        }
        phase = .sending
        do {
            // Block ONE real app the kid configured (exact app, by alias_key) —
            // NOT an all-apps reflection. The kid device applies it on its next
            // command poll; we poll the command's ack until confirmed. It
            // auto-releases in durationMinutes.
            let cmd = try await apiClient.queueOnboardingAppBlock(
                familyID: familyID,
                childDeviceID: childDeviceID,
                target: .appID(app.alias_key),
                durationMinutes: 5
            )
            blockCommandID = cmd
            if singleDevice {
                // Kid poller is off in parent mode → the ack-poll can only time out. Skip the
                // 30s dead-wait; the block is queued and applies when the tester switches to K.
                phase = .timedOut
                return
            }
            phase = .waitingForKid
            startBlockPoll(commandID: cmd)
        } catch {
            phase = .failed
        }
    }

    /// Poll /parent/state/{child} until the kid's phone reports it APPLIED the
    /// lock (`reflectionRequest.lockAppliedAt != nil`) or the ≤30s budget runs
    /// out (→ honest "queued" copy, never a fake checkmark).
    private func startBlockPoll(commandID: UUID) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var waited = 0
            while !Task.isCancelled && waited < Self.payoffBudgetSeconds {
                if let ack = try? await apiClient.fetchRichAckStatus(commandID: commandID) {
                    if ack.status == "confirmed" { phase = .landed; return }
                    if ack.status == "failed" { phase = .failed; return }
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
        // The block is a real, short, timed app-lock that auto-releases on the
        // kid device — no explicit cancel needed when the parent leaves.
    }
}

// MARK: - 10.5 · Try a reflection (separate demo after the block)

/// P2: a SEPARATE reflection demo AFTER the block. The parent is explicitly
/// prompted to try a Reflection; it auto-clears when they finish setup (cancel
/// on disappear + the §14.1 short cap backstop). It is NOT fired by the block.
struct ParentTryReflectionStep: View {
    let apiClient: APIClient
    let childDeviceID: UUID?
    let kidName: String
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var sent = false
    @State private var busy = false
    @State private var reflectionID: UUID?
    @State private var errorText: String?   // P6: trigger failures surface inline

    private var kid: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
    }

    /// P6: without a threaded child device id there is nothing to send to —
    /// show an explained, disabled state instead of silently faking success.
    private var hasKidDevice: Bool { childDeviceID != nil }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 11,
            stepTotal: parentTotal,
            title: "Now try a reflection",
            subtitle: sent
                ? "Sent! \(kid)'s phone will ask them to pause and reflect. It clears itself when you finish setup."
                : "A reflection asks \(kid) to stop and think before they keep scrolling — a gentler nudge than a hard block.",
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if hasKidDevice {
                        OnboardingV2ChatBubble(.me, text: "Have \(kid) take a quick reflection break")
                        OnboardingV2ChatBubble(.evlin, text: sent
                            ? "On its way — watch \(kid)'s screen."
                            : "I'll send a short reflection to \(kid)'s phone.")
                    } else {
                        // P6: explained state — no device id means the send
                        // button below is disabled, not a fake success.
                        OnboardingV2Card {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("No kid phone connected yet")
                                    .font(OnboardingV2Theme.Typography.bodyStrong)
                                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                                Text("We couldn't find \(kid)'s phone on this family, so a reflection can't be sent right now. You can skip and try it from Home later.")
                                    .onboardingV2BodyXS()
                            }
                        }
                    }
                    if busy {
                        HStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text("Sending…").onboardingV2BodyXS()
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.leading)
                    }
                }
            },
            footer: {
                if sent {
                    OnboardingV2PrimaryButton("Done", role: .parent, action: onContinue)
                } else {
                    OnboardingV2PrimaryButton(
                        busy ? "Sending…" : (errorText == nil ? "Send a reflection" : "Try again"),
                        systemImage: "sparkles", role: .parent
                    ) {
                        Task { await sendReflection() }
                    }
                    .disabled(busy || !hasKidDevice)
                    OnboardingV2SecondaryButton("Skip", action: onContinue)
                }
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .onDisappear {
            // Auto-clear at setup end: cancel the onboarding reflection when the
            // parent leaves this step (the short cap is the backstop).
            if let rid = reflectionID {
                Task { try? await apiClient.cancelChildReflection(reflectionId: rid) }
            }
        }
    }

    @MainActor
    private func sendReflection() async {
        // P6: no silent onContinue() here — a missing device id renders the
        // explained/disabled state above instead of faking a sent reflection.
        guard let childDeviceID else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let rid = try await apiClient.triggerOnboardingReflection(
                childDeviceID: childDeviceID,
                reason: "Let's try Reflection together",
                onboardingCapSeconds: 180
            )
            reflectionID = rid
            sent = true
        } catch {
            // P6: mirror ParentFirstActionsStep's failed treatment — honest
            // inline error + the button becomes "Try again".
            errorText = "Couldn't send the reflection. Check your connection and try again."
        }
    }
}

// MARK: - 12 · Set the Parent PIN (final — critical)

/// Final onboarding screen. The kid-device "Parent Controls" hub is PIN-gated,
/// but `EvlinPINGateView` CREATES the PIN on first open with no auth
/// (`isFirstRun = !store.isSet()`) — so whoever opens it first owns it. If the
/// parent doesn't claim the PIN now, the child can open Parent Controls on
/// their own phone, set their OWN PIN, and then switch off app blocking +
/// delete-protection + sign out — locking the parent out entirely. This screen
/// makes that stakes explicit before setup completes.
struct ParentSetParentPINStep: View {
    let kidName: String
    var singleDevice: Bool = false
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    private var kid: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your child" : t
    }

    private var howText: String {
        singleDevice
            ? "After you tap Done, use the Parent / Kid toggle to switch to the kid side, open Parent Controls, and create your PIN."
            : "On \(kid)'s phone, open Evlin → tap Parent Controls → create your PIN. Do this before you hand the phone back."
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 12,
            stepTotal: parentTotal,
            title: "Set your Parent PIN now",
            subtitle: "This is the most important step — please don't skip it.",
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(OnboardingV2Theme.Palette.error)
                                Text("If you skip this")
                                    .font(OnboardingV2Theme.Typography.bodyStrong)
                                    .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                            }
                            Text("\(kid) can open Parent Controls on their phone and set the PIN themselves — then turn off app blocking, switch off delete-protection, remove Evlin, and lock you out.")
                                .onboardingV2BodyXS()
                        }
                    }
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Do this now")
                                .font(OnboardingV2Theme.Typography.bodyStrong)
                                .foregroundStyle(OnboardingV2Theme.Palette.onSurface)
                            Text(howText)
                                .onboardingV2BodyXS()
                        }
                    }
                }
            },
            footer: {
                OnboardingV2PrimaryButton("Done", role: .parent, action: onContinue)
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
    }
}

// MARK: - 11 · It works

/// Mockup M[16].parent — "Sent ✓": a receipt card for the landed block, with an
/// "End now" affordance and the "you'll get a ping" footnote.
///
/// P5: `landed` is threaded from ParentFirstActionsStep via the coordinator —
/// `true` only when the kid's phone CONFIRMED the lock applied. When the
/// parent arrives via "Skip for now" (timed out / failed) the copy honestly
/// says the block is queued instead of claiming "it landed".
struct ParentItWorksStep: View {
    let apiClient: APIClient
    var familyID: UUID? = nil
    var childDeviceID: UUID? = nil
    var kidName: String = ""
    var blockAppName: String = "the app"
    var firstBlockApp: ChildReadinessDTO.App? = nil
    /// P5: did the kid's phone confirm the first block applied?
    var landed: Bool = true
    let onContinue: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var ending = false
    @State private var ended = false        // P7: confirmed unblock ack only
    @State private var endQueued = false    // P7: ack timed out — command still queued
    @State private var endFailed = false

    private var kid: String {
        let t = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your kid" : t
    }

    private var endButtonTitle: String {
        if ended { return "Ended" }
        if endQueued { return "Unblock queued" }
        if ending { return "Ending…" }
        return "End now"
    }

    /// P5/P7 honest status line: confirmed end → "Ended"; un-acked end →
    /// "queued"; landed block → the live countdown copy; un-landed block →
    /// "applies on next check-in".
    private var receiptStatusText: String {
        if ended { return "Ended on \(kid)'s phone" }
        if endQueued { return "Unblock queued — ends on their next check-in" }
        if landed { return "Unblocks in a few minutes · you can end it anytime" }
        return "Applies when their phone next checks in · auto-releases shortly after"
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 11,
            stepTotal: parentTotal,
            title: landed ? "Sent" : "Queued",
            subtitle: landed
                ? "\(kid)'s \(blockAppName) is blocked for 5 minutes. Check their phone — it landed."
                : "Block queued — it applies when \(kid)'s phone next checks in. It auto-releases so it can't get stuck.",
            dotsCount: parentTotal,
            dotsCurrent: 10,
            content: {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    OnboardingV2Card {
                        VStack(alignment: .leading, spacing: OnboardingV2Theme.Metrics.ctaRowSpacing) {
                            OnboardingV2AppIcon(letter: String(blockAppName.prefix(1)).uppercased(), fill: .black)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(landed ? "\(blockAppName) · blocked" : "\(blockAppName) · block queued")
                                    .onboardingV2BodyStrong()
                                Text(receiptStatusText)
                                    .onboardingV2BodyXS()
                            }
                            OnboardingV2SecondaryButton(endButtonTitle) {
                                Task { await endNow() }
                            }
                            .disabled(ending || ended || endQueued)
                                .padding(.top, Spacing.sm)
                            if endFailed {
                                Text("Couldn't end it yet. Try again or wait for the short timer.")
                                    .onboardingV2BodyXS()
                                    .foregroundStyle(Color.evError)
                            }
                        }
                    }

                    Text("You'll get a ping if \(kid) asks to unblock.")
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

    @MainActor
    private func endNow() async {
        guard let familyID, let childDeviceID, let app = firstBlockApp else {
            endFailed = true
            return
        }
        ending = true
        endFailed = false
        defer { ending = false }
        do {
            let commandID = try await apiClient.queueOnboardingAppUnblock(
                familyID: familyID,
                childDeviceID: childDeviceID,
                target: .appID(app.alias_key)
            )
            var waited = 0
            while waited < 18 {
                let ack = try await apiClient.fetchRichAckStatus(commandID: commandID)
                if ack.status == "confirmed" {
                    ended = true
                    return
                }
                if ack.status == "failed" {
                    endFailed = true
                    return
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                waited += 3
            }
            // P7: the ack never arrived inside the budget — the child may be
            // asleep and the command is still QUEUED. Don't claim "Ended on
            // <kid>'s phone"; show the honest "queued — ends on next check-in"
            // state instead (the button still reflects that it did something).
            endQueued = true
        } catch {
            endFailed = true
        }
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
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                let on = i == selectedIndex
                Button { selectedIndex = i } label: {
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
                .buttonStyle(.plain)
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

private struct OnboardingV2WaitingPill: View {
    let title: String
    @State private var spin = false

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(OnboardingV2Theme.Palette.onPrimary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
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
                .fill(OnboardingV2Theme.Palette.primary.opacity(0.82))
        )
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
