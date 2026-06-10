import SwiftUI

// Onboarding v2 — PARENT co-parent-join + returning-parent recovery screens.
//
// Plan 5: a parent who chose "Join an existing family" entered a co-parent
// invite code. The coordinator already POSTed /family/invite/consume; with
// owner-approval ON the backend returns `pending_approval` and does NOT yet
// bind account.family_id. `ParentCoParentJoinStep` shows the honest
// "waiting for the owner to approve" state and polls GET /family/me (PIN B,
// 🔑 get_current_account — safe for a family_id==nil account) until the owner
// approves and account.familyID binds, then advances (it does NOT pair a kid).
//
// Plan 8: `ParentBackInInstantlyStep` is the recovery + co-parent landing
// screen — register this device via POST /family/device/register, load the
// FamilyStore, and finish onboarding. Reached by (a) a returning parent who
// already has a family on a new device, and (b) an approved co-parent.

private let parentTotal = 12

// MARK: - Co-parent: waiting for owner approval

/// Plan 5 — "Waiting for approval". The co-parent consumed the invite; the
/// owner must approve before the family binds. Polls GET /family/me until
/// `account.familyID` becomes non-null, then advances to the recovery landing.
struct ParentCoParentJoinStep: View {
    let apiClient: APIClient
    /// Called once the owner approves (account.familyID bound) — the coordinator
    /// advances to `parentBackInInstantly`.
    let onApproved: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var pollTask: Task<Void, Never>?
    @State private var elapsed = 0

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Accounts",
            stepIndex: 5,
            stepTotal: parentTotal,
            title: "Waiting for approval",
            subtitle: "We've sent your request to the family owner. "
                    + "As soon as they approve you, your family appears here.",
            dotsCount: parentTotal,
            dotsCurrent: 4,
            content: {
                OnboardingV2WaitingSpinner(
                    name: "the owner",
                    subtitle: "You can keep this open or come back later — "
                            + "we'll connect you the moment they approve."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                if let onBack { OnboardingV2BackLink(action: onBack) }
            }
        )
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                // PIN B: the consumed-but-not-approved co-parent has
                // family_id == nil and MUST NOT poll a 👪 route (it would 403
                // family_required). /family/me is 🔑 get_current_account and
                // flips account.familyID from nil → non-nil on owner approval.
                if let me = try? await apiClient.fetchFamilyMe(),
                   me.account.familyID != nil {
                    onApproved()
                    break
                }
                elapsed += 5
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

// MARK: - Returning parent / approved co-parent: back in instantly

/// Plan 8 — "Welcome back". The landing screen for a returning parent on a new
/// device AND for an approved co-parent. Registers this device via
/// POST /family/device/register, loads the FamilyStore, then finishes. No
/// new-family onboarding, no kid pairing.
struct ParentBackInInstantlyStep: View {
    let apiClient: APIClient
    /// Registers this device as a parent device (POST /family/device/register)
    /// + loads the FamilyStore. Returns `.success` with the resolved family
    /// display name (or nil) so the copy reads "Welcome back to <family>", or
    /// `.failure` when nothing could actually be recovered (e.g. offline:
    /// device-register failed AND the family aggregate didn't load) — which
    /// renders the failed + "Try again" state (P4). Injected by the coordinator
    /// where the FamilyStore + device-info are in scope.
    let recover: () async -> Result<String?, Error>
    /// Called when recovery is complete — the coordinator finishes onboarding.
    let onDone: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var phase: Phase = .working
    @State private var familyName: String?
    @State private var errorText: String?

    enum Phase: Equatable { case working, ready, failed }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "5 · Parent finish",
            stepIndex: 11,
            stepTotal: parentTotal,
            title: phase == .working ? "Getting your family back…" : "Welcome back",
            subtitle: subtitle,
            dotsCount: parentTotal,
            dotsCurrent: 10,
            content: {
                VStack(spacing: Spacing.xl) {
                    switch phase {
                    case .working:
                        OnboardingV2WaitingSpinner(
                            name: "your family",
                            subtitle: "Reconnecting this device to your family."
                        )
                    case .ready:
                        OnboardingV2SuccessCheck(role: .parent, size: 62)
                        Text(familyName.map { "You're back in \($0)." }
                                ?? "You're back in.")
                            .onboardingV2Body()
                            .multilineTextAlignment(.center)
                    case .failed:
                        Text(errorText ?? "We couldn't reconnect this device. Try again.")
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.error)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                switch phase {
                case .working:
                    EmptyView()
                case .ready:
                    OnboardingV2PrimaryButton("Go to Home", role: .parent, action: onDone)
                case .failed:
                    OnboardingV2PrimaryButton("Try again", role: .parent) {
                        Task { await runRecovery() }
                    }
                    if let onBack { OnboardingV2BackLink(action: onBack) }
                }
            }
        )
        .task { await runRecovery() }
    }

    private var subtitle: String? {
        switch phase {
        case .working: return "One moment while we restore your family on this device."
        case .ready:   return "Your children and settings are right where you left them."
        case .failed:  return nil
        }
    }

    @MainActor
    private func runRecovery() async {
        phase = .working
        errorText = nil
        // P4: recovery can FAIL (offline / backend down) — surface it so the
        // existing phase == .failed "Try again" UI is actually reachable
        // instead of unconditionally claiming "Welcome back".
        switch await recover() {
        case .success(let name):
            familyName = name
            phase = .ready
        case .failure(let error):
            errorText = error.localizedDescription
            phase = .failed
        }
    }
}
