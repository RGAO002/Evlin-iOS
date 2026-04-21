import SwiftUI

// MARK: - Child Profile Model (aligned to Esen's EvlinFamily)

struct ChildProfile: Identifiable, Hashable {
    enum Status: String, Hashable { case unlocked, locked }

    let id: String              // "liam" / "maya" / "emma"
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

// MARK: - Mock Data (mirrors frontend_for_app_evlin/tokens.js verbatim)

extension ChildProfile {
    static let liam = ChildProfile(
        id: "liam",
        name: "Liam",
        age: 12,
        avatarURL: "https://lh3.googleusercontent.com/aida-public/AB6AXuBka2hek2iCWOSQRWVwFCLdYUcsh87WZfrhCtc5YQ5YDn4ihWAzq5t8HypHJUMHa8XKcjzVTPucfTrO3jKUrXFVxRlRbXkV4aZRQTLzW7GAkR-wG1K7IR4dGBA6Q_QMB2H1iTH0byjAnA_LVUBsFUmmOxrwhpOhP538V8NhmgvYx6RKGtCOJNRjtbwMhL8zgSp-ymKuimRWWitAARSaq8BoR_GYesFIxUs0cZrbGWSs6xntdfYxbsLs5SDYLStU5AUBgmt4WxHqDoA",
        accentColor: .evChildLiam,
        status: .unlocked,
        timeLeft: "1h 30m",
        timePct: 0.75,
        subtitle: "Focused today · 3 of 5 tasks done"
    )

    static let maya = ChildProfile(
        id: "maya",
        name: "Maya",
        age: 8,
        avatarURL: "https://i.pravatar.cc/256?img=47",
        accentColor: .evChildMaya,
        status: .unlocked,
        timeLeft: "45m",
        timePct: 0.38,
        subtitle: "On bedtime wind-down in 2h"
    )

    static let emma = ChildProfile(
        id: "emma",
        name: "Emma",
        age: 6,
        avatarURL: "https://i.pravatar.cc/256?img=16",
        accentColor: .evChildEmma,
        status: .locked,
        timeLeft: "0m",
        timePct: 0.0,
        subtitle: "Quiet time · unlocks at 4:00 PM"
    )

    static let all: [ChildProfile] = [.liam, .maya, .emma]
}
