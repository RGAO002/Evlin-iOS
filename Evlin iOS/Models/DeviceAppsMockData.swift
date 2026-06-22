import SwiftUI

/// Per-app data for DeviceAppsSheet. Mirrors HTML 627-644 (APP_DATA).
struct DeviceAppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let iconSystemName: String
    let brandColor: Color
    let bgColor: Color
    var enabled: Bool = true
    var usedMin: Int        // minutes used today
    var limitMin: Int       // current limit
    var artworkURL: URL? = nil
    /// App Store bundle id (from the catalog target). Required to set/clear a
    /// backend limit — `nil` means the app can't be limited (pill disabled).
    var bundleID: String? = nil
    /// Backend rule id once a limit exists. `nil` = no active rule (limit off);
    /// carried so the toggle/clear can DELETE the right rule.
    var ruleID: UUID? = nil
}

enum DeviceAppsMockData {
    static func apps(for childId: String) -> [DeviceAppItem] {
        switch childId {
        case "liam":
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 75, limitMin: 60),
                .init(id: "roblox",    name: "Roblox",    iconSystemName: "gamecontroller",
                      brandColor: Color(hex: 0xE2231A), bgColor: Color.black,
                      usedMin: 45, limitMin: 30),
                .init(id: "tiktok",    name: "TikTok",    iconSystemName: "music.note",
                      brandColor: Color(hex: 0xFF0050), bgColor: Color.black,
                      usedMin: 20, limitMin: 20),
                .init(id: "minecraft", name: "Minecraft", iconSystemName: "square.grid.3x3",
                      brandColor: Color(hex: 0x4CAF50), bgColor: Color(hex: 0x5C4033),
                      usedMin: 0, limitMin: 45),
            ]
        case "maya":
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 30, limitMin: 45),
                .init(id: "spotify",   name: "Spotify",   iconSystemName: "headphones",
                      brandColor: Color(hex: 0x1DB954), bgColor: Color(hex: 0x191414),
                      usedMin: 60, limitMin: 90),
                .init(id: "duolingo",  name: "Duolingo",  iconSystemName: "character.book.closed",
                      brandColor: Color(hex: 0x58CC02), bgColor: Color.white,
                      usedMin: 15, limitMin: 30),
            ]
        default:  // emma
            return [
                .init(id: "youtube",   name: "YouTube",   iconSystemName: "play.tv",
                      brandColor: Color(hex: 0xFF0000), bgColor: Color.white,
                      usedMin: 0,  limitMin: 20),
                .init(id: "netflix",   name: "Netflix",   iconSystemName: "film",
                      brandColor: Color(hex: 0xE50914), bgColor: Color.black,
                      usedMin: 0,  limitMin: 30),
                .init(id: "khan",      name: "Khan Kids", iconSystemName: "graduationcap",
                      brandColor: Color(hex: 0x14BF96), bgColor: Color.white,
                      usedMin: 0,  limitMin: 60),
            ]
        }
    }

    // 15m is the lowest budget offered in release builds. DEBUG builds also
    // expose a 1-minute option (no separate label — it just shows "1m") so the
    // threshold/shield path can be tested end to end without waiting. The
    // backend accepts `daily_budget_minutes >= 1` and `formatLimit(1)` → "1m".
    #if DEBUG
    static let limitOptions: [Int] = [1, 15, 20, 30, 45, 60, 90, 120]
    #else
    static let limitOptions: [Int] = [15, 20, 30, 45, 60, 90, 120]
    #endif

    static func formatLimit(_ min: Int) -> String {
        if min >= 60 {
            let h = min / 60
            let m = min % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(min)m"
    }

    static func formatUsed(_ min: Int) -> String {
        if min >= 60 {
            return "\(min / 60)h \(min % 60)m"
        }
        return "\(min)m"
    }
}

// MARK: - App ↔ rule merge (P9)

/// A backend per-app rule reduced to just the fields the merge needs. Lets the
/// merge logic be unit-tested without depending on the full `AppLimitRuleDTO`
/// (which lives inside APIClient) — the view adapts the real DTO into this.
struct AppLimitRuleSummary: Equatable {
    let ruleID: UUID
    let bundleID: String
    let dailyBudgetMinutes: Int
}

// MARK: - Optimistic-update supersession (P9 review)

/// Pure decision for whether an in-flight optimistic-edit response may still
/// touch state. Each `pickLimit`/`toggleLimit` interaction captures a
/// per-app monotonic token at the start; when its `await` resumes it compares
/// the captured token against the current one. Only the latest interaction
/// (`current == captured`) is authoritative — an earlier, slower response is
/// `.superseded` and must be a NO-OP (neither its success write-back nor its
/// failure revert may run). This prevents a slow earlier response overwriting a
/// newer selection, a failure reverting to a now-stale snapshot, and the
/// enabled/ruleID desync from toggling off before an earlier POST returns.
///
/// Kept free of SwiftUI so it can be unit-tested without the view.
enum AppLimitEditDecision: Equatable {
    case apply
    case superseded

    /// `.apply` only when the resumed interaction is still the latest one for
    /// the app (its captured token equals the current token). Any later
    /// interaction (current > captured) supersedes it → `.superseded`.
    static func decide(currentSeq: Int?, capturedSeq: Int) -> AppLimitEditDecision {
        (currentSeq == capturedSeq) ? .apply : .superseded
    }
}

enum DeviceAppLimitMerge {
    /// Overlay loaded backend rules onto freshly-built catalog rows (which start
    /// with the hardcoded default `limitMin`, `enabled: true`). Matching is by
    /// `bundleID`:
    ///   • app WITH a rule  → limitMin = rule budget, enabled = true,  ruleID set
    ///   • app WITHOUT a rule → enabled = false (limit off), ruleID = nil
    ///     (the default `limitMin` stays so the pill still shows a sensible value)
    /// Apps with no bundleID can never match a rule → always "limit off".
    static func apply(rules: [AppLimitRuleSummary], to apps: [DeviceAppItem]) -> [DeviceAppItem] {
        let byBundle = Dictionary(rules.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        return apps.map { app in
            var updated = app
            if let bundle = app.bundleID, let rule = byBundle[bundle] {
                updated.limitMin = rule.dailyBudgetMinutes
                updated.enabled = true
                updated.ruleID = rule.ruleID
            } else {
                updated.enabled = false
                updated.ruleID = nil
            }
            return updated
        }
    }
}
