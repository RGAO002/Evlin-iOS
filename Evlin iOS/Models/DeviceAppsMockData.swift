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

    static let limitOptions: [Int] = [15, 20, 30, 45, 60, 90, 120]

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
