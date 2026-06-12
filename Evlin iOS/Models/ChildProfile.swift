import SwiftUI

// MARK: - Child Profile Model (aligned to Esen's EvlinFamily)

struct ChildProfile: Identifiable, Hashable {
    enum Status: String, Hashable { case unlocked, locked }

    let id: String              // backend child id (UUID string) — was "liam"/"maya"/"emma"
    let name: String
    let age: Int
    let avatarURL: String?
    let accentColor: Color
    let status: Status
    let timeLeft: String        // "1h 30m"
    let timePct: Double         // 0.0 ... 1.0
    let subtitle: String

    var initial: String { String(name.prefix(1)).uppercased() }
}

// MARK: - Backend adapter (spec §6.3)

extension ChildProfile {
    /// Build a presentation `ChildProfile` from the backend `ChildDTO`
    /// (`GET /me/profile` / `GET /family`). The Home tab now sources its
    /// children from `FamilyStore.childProfiles`, which maps each `ChildDTO`
    /// through this initializer.
    ///
    /// Fields not yet provided by the aggregate (live time-budget / lock
    /// status / subtitle) get neutral defaults — they are owned by other
    /// surfaces and will be wired as those endpoints land. The avatar photo
    /// (when `kind == "photo"`) is the short-lived `signed_url`; the avatar's
    /// `color` hex drives the accent so each child keeps a stable tint.
    /// `locked` carries the kid device's REAL all-apps lock state (from
    /// `GET /parent/device/lock-state`, threaded by `FamilyStore`) so the Home
    /// card + filter pills reflect whether the child is actually locked instead
    /// of a hardcoded `.unlocked`. Defaults to unlocked for callers without the
    /// live state.
    init(dto: ChildDTO, locked: Bool = false) {
        self.id = dto.id
        self.name = dto.display_name
        self.age = dto.age ?? 0
        self.avatarURL = dto.avatar.signed_url
        self.accentColor = ChildProfile.color(fromHex: dto.avatar.color) ?? .evPrimary
        self.status = locked ? .locked : .unlocked
        self.timeLeft = "2h"
        self.timePct = 1.0
        self.subtitle = ""
    }

    /// Parse a `#RRGGBB` hex string into a SwiftUI `Color`. Returns nil for
    /// unparseable input so the caller can fall back to a default accent.
    private static func color(fromHex hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

// MARK: - Preview / fallback fixtures (NOT a live data source)

extension ChildProfile {
    /// Fixed fixtures for screens NOT yet migrated to real data (Calendar/
    /// Reflection/Chat/Task previews). These REPLACE the deleted
    /// `.liam/.maya/.emma` and are referenced by PRODUCTION (non-`#if DEBUG`)
    /// code (e.g. `ParentReflectionModels.swift`, `TaskDetailView` fallback),
    /// so they must exist in ALL build configs — do NOT wrap in `#if DEBUG`
    /// (§15.8 R-iOS: a Debug-only guard breaks the Release/TestFlight build).
    /// NOT a live Home data source — the Home tab reads
    /// `FamilyStore.childProfiles` (spec §6.3).
    static let previewLiam = ChildProfile(
        id: "liam", name: "Liam", age: 12,
        avatarURL: nil, accentColor: .evChildLiam, status: .unlocked,
        timeLeft: "1h 30m", timePct: 0.75, subtitle: "Focused today"
    )
    static let previewMaya = ChildProfile(
        id: "maya", name: "Maya", age: 8,
        avatarURL: nil, accentColor: .evChildMaya, status: .unlocked,
        timeLeft: "45m", timePct: 0.38, subtitle: "Wind-down soon"
    )
    static let previewEmma = ChildProfile(
        id: "emma", name: "Emma", age: 6,
        avatarURL: nil, accentColor: .evChildEmma, status: .locked,
        timeLeft: "0m", timePct: 0.0, subtitle: "Quiet time"
    )

    /// Aggregate fixture — replaces the deleted `.all` for the OUT-OF-SCOPE
    /// consumers (Chat/Task previews) and any production fallback. NOT a live
    /// data source; live Home data comes from `FamilyStore.childProfiles`.
    static let previewAll: [ChildProfile] = [previewLiam, previewMaya, previewEmma]
}
