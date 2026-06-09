import Foundation

/// Plan 7 — PURE, UI-free logic for `ParentFirstActionsStep` (spec §8). Kept
/// testable + decoupled from SwiftUI: the block-target fallback chain, the
/// action phase, and honest copy.

/// First-actions phase. idle → sending → waitingForKid → landed | timedOut | failed.
enum FirstActionPhase: Equatable, Sendable {
    case idle
    case sending
    case waitingForKid
    case landed
    case timedOut
    case failed
}

enum FirstActionsLogic {

    /// §8 first-block target. The parent can send the first test block only
    /// after the kid device has registered a real lockable app. Do not fall back
    /// to a synthetic app/category here; that would bypass the readiness gate
    /// and make onboarding look ready before the kid phone is configured.
    static func blockTarget(firstCatalogAppAliasKey: UUID?) -> FirstBlockTarget? {
        if let key = firstCatalogAppAliasKey { return .appID(key) }
        return nil
    }

    /// §8 honest payoff copy — never a fake checkmark. `landed` is the only
    /// state that truthfully claims the kid applied the lock.
    static func payoffSubtitle(phase: FirstActionPhase, kidName: String) -> String {
        let name = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kid = name.isEmpty ? "your kid" : name
        switch phase {
        case .idle:
            return "Let's make sure it actually goes through. Tap below to send a real test block to \(kid)'s phone."
        case .sending:
            return "Sending the block to \(kid)'s phone…"
        case .waitingForKid:
            return "Block sent. Waiting for \(kid)'s phone to apply it — keep watching their screen."
        case .landed:
            return "It works — \(kid)'s phone applied the lock. That's the real thing."
        case .timedOut:
            return "Queued — it'll apply on \(kid)'s next check-in. Make sure \(kid) has finished setup and is online."
        case .failed:
            return "We couldn't send the test block. Check your connection and try again."
        }
    }
}
