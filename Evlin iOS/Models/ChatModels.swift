import Foundation

extension Notification.Name {
    static let evlinClearChat = Notification.Name("evlinClearChat")
    static let evlinLockStateChanged = Notification.Name("evlinLockStateChanged")
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    var reasoning: String?

    // Card data (persisted)
    var lockMinutes: Int?
    var lockChildName: String?
    var isSafetyCard: Bool?
    var videoTitle: String?
    var videoDescription: String?
    var videoThumbnail: String?
    var videoId: String?

    // Strategy artifact (Task 20)
    var strategyTitle: String? = nil
    var strategyStatus: String? = nil
    var strategyCategory: String? = nil
    var strategyVideoLabel: String? = nil
    var strategyVideoDuration: String? = nil
    var strategyTip: String? = nil

    // Receipt state (Phase 9 P1-1 fix).
    // When an agent message originates from a queued Command, we track the
    // child's ack here. ChatView renders ReceiptCard(state, effectiveState)
    // beneath the bubble. Nil until the ack poll resolves.
    var commandID: UUID? = nil
    var receiptState: ReceiptState? = nil
    var receiptEffectiveState: AckEffectiveState? = nil

    // Agent envelope (Phase D/E — global AI copilot).
    // When AGENT_ENABLED=1, /parent/chat may return staged proposals
    // (parent must confirm) and/or executed receipts (with optional undo).
    // ChatView renders ProposalCard / ReceiptBubble beneath the bubble.
    var proposals: [ProposalDTO]? = nil
    var receipts: [ReceiptDTO]? = nil

    var isStrategyArtifact: Bool { strategyTitle != nil }

    init(role: ChatRole, content: String, timestamp: Date = Date(), reasoning: String? = nil, action: ChatAction? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.reasoning = reasoning
    }
}

enum ChatAction {
    case lockDevice(minutes: Int, childName: String)
    case unlockDevice(childName: String)
    case adjustRules(description: String)
    case none
}

/// Card type embedded in AI response
enum ChatCardType: String, Codable {
    case lockConfirmation
    case safetyStatus
    case videoRecommendation
    case none
}

struct QuickPrompt {
    let icon: String
    let text: String

    static let defaults: [QuickPrompt] = [
        QuickPrompt(icon: "checkmark.circle", text: "Review today's compliance"),
        QuickPrompt(icon: "shield", text: "Is Liam safe?"),
        QuickPrompt(icon: "moon", text: "Adjust bedtime strategy"),
        QuickPrompt(icon: "lock", text: "Lock phone for 30 min"),
    ]
}
