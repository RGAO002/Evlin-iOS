import Foundation

/// Inline reflection review surfaced in Chat (kid essay submitted → parent approves).
/// Same lifecycle as `ParentBigKidDebugSheet.approveReflection` / `refreshKidState`.
struct ReflectionSubmissionReviewPayload: Codable, Equatable, Sendable {
    let reflectionId: UUID
    let writingPrompt: String
    let essayText: String
    var resolved: Bool

    init(reflectionId: UUID, writingPrompt: String, essayText: String, resolved: Bool = false) {
        self.reflectionId = reflectionId
        self.writingPrompt = writingPrompt
        self.essayText = essayText
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey {
        case reflectionId, writingPrompt, essayText, resolved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reflectionId = try c.decode(UUID.self, forKey: .reflectionId)
        writingPrompt = try c.decode(String.self, forKey: .writingPrompt)
        essayText = try c.decode(String.self, forKey: .essayText)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reflectionId, forKey: .reflectionId)
        try c.encode(writingPrompt, forKey: .writingPrompt)
        try c.encode(essayText, forKey: .essayText)
        try c.encode(resolved, forKey: .resolved)
    }
}

/// When the parent approves a submitted reflection via Chat (or the
/// new Step-3 message input) but leaves the note field empty, we
/// still POST these defaults so the child always sees something
/// constructive on-device.
enum ReflectionParentNoteFallback {
    static let thanksHonest = "Thanks for being honest."
    /// Default coaching message sent when the parent taps "Request
    /// redo" without typing anything. Firm-but-warm, asks the kid to
    /// actually reflect rather than just re-submit the same essay.
    static let redoTakeAnotherLook = "Take another look — try to write a bit more honestly about what happened and how you felt."
}

extension Notification.Name {
    static let evlinClearChat = Notification.Name("evlinClearChat")
    static let evlinLockStateChanged = Notification.Name("evlinLockStateChanged")

    /// DEBUG-only: emitted by the child-side pairing screen when the
    /// "Single-device testing? Switch to Parent" button is tapped.
    /// `OnboardingCoordinator` listens for this and jumps to the parent's
    /// `parentPairingCode` step so the same device can enter the code that
    /// was just generated. The pairing code itself is passed via the
    /// `evlin.dev.pendingPairingCode` UserDefaults key (cleared after read).
    static let evlinSingleDeviceJumpToParent =
        Notification.Name("evlinSingleDeviceJumpToParent")
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

    /// Big-kid: kid submitted reflection essay (`status=submitted`). Approve path = debug sheet.
    var reflectionSubmissionReview: ReflectionSubmissionReviewPayload? = nil

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
