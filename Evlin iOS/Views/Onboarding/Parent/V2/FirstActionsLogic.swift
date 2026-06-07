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

    /// §8 fallback chain for the block target. Prefer the kid's first real added
    /// app (by alias_key → `app_id`); otherwise the guaranteed "Games" category
    /// by name. "TikTok" by-name is the last resort, escalated by the caller
    /// only after the Games attempt 422s on real hardware.
    static func blockTarget(firstCatalogAppAliasKey: UUID?) -> FirstBlockTarget {
        if let key = firstCatalogAppAliasKey { return .appID(key) }
        return .appName("Games")
    }

    /// Last-resort by-name target when both the catalog app AND the Games
    /// category are unresolved on real hardware (§8 — avoids the 422 flake).
    static let lastResortTarget: FirstBlockTarget = .appName("TikTok")

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
