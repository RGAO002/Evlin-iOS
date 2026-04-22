import SwiftUI

enum LibraryMockData {
    static let reels: [ReelItem] = [
        ReelItem(title: "Morning mindfulness for busy parents",
                 author: "Dr. Julian Vance",
                 gradient: LinearGradient(colors: [Color(hex: 0xEF6C00), Color(hex: 0x261000)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "The \"No-Phone\" Zone Protocol",
                 author: "Elena Rodriguez",
                 gradient: LinearGradient(colors: [Color(hex: 0x1A2B3C), Color(hex: 0x041627)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "Tantrum de-escalation playbook",
                 author: "Dr. Mira Shah",
                 gradient: LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x1B4A1C)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
        ReelItem(title: "When screen time is actually OK",
                 author: "Prof. Aisha Green",
                 gradient: LinearGradient(colors: [Color(hex: 0x6E3900), Color(hex: 0x261000)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    static let lessons: [LessonItem] = [
        LessonItem(
            author: "Dr. Julian Vance",
            role: "Pediatric Neuropsychologist",
            title: "The \"Three-Second\" Pause Method",
            excerpt: "A neuro-scientific approach to de-escalating toddler tantrums before they peak.",
            hearts: "2.4k",
            comments: 184
        ),
        LessonItem(
            author: "Elena Rodriguez",
            role: "Digital Wellness Strategist",
            title: "Digital Sovereignty Protocols",
            excerpt: "Building a child's internal moral compass for digital spaces. Frameworks for the AI era.",
            hearts: "1.1k",
            comments: 56
        ),
    ]

    static let categories: [CategoryTileInfo] = [
        .init(id: "ei", label: "Emotional Intelligence", count: "12 series",
              iconSystemName: "brain",
              gradient: LinearGradient(colors: [Color(hex: 0x1A2B3C), Color(hex: 0x041627)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "digital", label: "Digital Boundaries", count: "8 series",
              iconSystemName: "shield",
              gradient: LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x1B4A1C)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "conflict", label: "Conflict Resolution", count: "15 series",
              iconSystemName: "hands.sparkles",
              gradient: LinearGradient(colors: [Color(hex: 0x6E3900), Color(hex: 0x261000)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
        .init(id: "growth", label: "Growth Mindset", count: "20 series",
              iconSystemName: "arrow.up.right.circle",
              gradient: LinearGradient(colors: [Color(hex: 0x0B1D2D), Color.black],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    struct DetailItem: Identifiable, Hashable {
        let id = UUID()
        let kind: Kind
        let title: String
        let meta: String
        enum Kind { case video, article }
    }

    static func detail(for categoryId: String) -> (heroTitle: String, heroAuthor: String, items: [DetailItem]) {
        switch categoryId {
        case "ei":
            return ("Emotional Intelligence in practice", "Dr. Julian Vance", [
                .init(kind: .video, title: "Naming feelings with toddlers", meta: "6 min video"),
                .init(kind: .article, title: "The wheel of emotions", meta: "5 min read"),
                .init(kind: .video, title: "Co-regulation basics", meta: "8 min video"),
                .init(kind: .article, title: "Empathy vs sympathy", meta: "4 min read"),
            ])
        case "digital":
            return ("Building digital boundaries that stick", "Elena Rodriguez", [
                .init(kind: .video, title: "The family phone contract", meta: "10 min video"),
                .init(kind: .article, title: "Screen-free dinner rule", meta: "3 min read"),
                .init(kind: .video, title: "Digital sunset for teens", meta: "7 min video"),
                .init(kind: .article, title: "Device-free homework", meta: "5 min read"),
            ])
        case "conflict":
            return ("Conflict resolution starter pack", "Dr. Mira Shah", [
                .init(kind: .video, title: "Calm-down corners", meta: "5 min video"),
                .init(kind: .article, title: "Sibling mediation steps", meta: "6 min read"),
                .init(kind: .video, title: "Naming the need", meta: "9 min video"),
                .init(kind: .article, title: "Repair after rupture", meta: "4 min read"),
            ])
        default:
            return ("Cultivating growth mindset", "Prof. Aisha Green", [
                .init(kind: .video, title: "Praise the effort", meta: "8 min video"),
                .init(kind: .article, title: "Yet: the magic word", meta: "3 min read"),
                .init(kind: .video, title: "Failure stories at dinner", meta: "6 min video"),
                .init(kind: .article, title: "Progress over perfection", meta: "5 min read"),
            ])
        }
    }
}
