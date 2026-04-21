import SwiftUI

// MARK: - Child Profile Model

struct ChildProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let age: Int
    let avatarEmoji: String
    let accentColor: Color

    /// Initials for avatar fallback
    var initials: String {
        name.prefix(1).uppercased()
    }
}

// MARK: - Mock Data

extension ChildProfile {
    static let liam = ChildProfile(
        id: "liam",
        name: "Liam",
        age: 10,
        avatarEmoji: "🦊",
        accentColor: Color(hex: 0x1B6D24) // evSecondary green
    )

    static let emma = ChildProfile(
        id: "emma",
        name: "Emma",
        age: 8,
        avatarEmoji: "🐨",
        accentColor: Color(hex: 0xDA7807) // evTertiaryContainer amber
    )

    static let sophia = ChildProfile(
        id: "sophia",
        name: "Sophia",
        age: 13,
        avatarEmoji: "🦄",
        accentColor: Color(hex: 0x6B4FBB) // editorial purple
    )

    static let all: [ChildProfile] = [.liam, .emma, .sophia]
}
