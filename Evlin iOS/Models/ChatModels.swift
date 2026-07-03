import Foundation

/// Tri-state for the chat reflection-review card header pill.
/// `.open` → kid submitted, parent hasn't acted (yellow chip).
/// `.approved` → parent tapped "Good enough" (green check).
/// `.sentBack` → parent tapped "Write again" (red chip).
enum ReflectionReviewStatus: String, Codable, Equatable, Sendable {
    case open
    case approved
    case sentBack
}

/// Inline reflection review surfaced in Chat (kid essay submitted → parent approves).
/// Same lifecycle as `ParentBigKidDebugSheet.approveReflection` / `refreshKidState`.
struct ReflectionSubmissionReviewPayload: Codable, Equatable, Sendable {
    let reflectionId: UUID
    let writingPrompt: String
    let essayText: String
    var status: ReflectionReviewStatus
    /// Backend `submitted_at` — drives the card subtitle "just now /
    /// 5m ago / 2h ago" relative-time prefix.
    var submittedAt: Date?
    /// AI-summarised ≤3-word category chip from the backend
    /// `ReflectionRequest.topicLabel`. Drives the card subtitle's
    /// post-`·` text. nil → caller falls back to nothing or to a
    /// truncated reason.
    var topicLabel: String?
    /// Mirrors `ReflectionRequest.stepsCompleted`. Drives the three
    /// step pills (video / quiz / essay) under the header.
    var stepsCompleted: [BigKidReflectionStep]

    init(
        reflectionId: UUID,
        writingPrompt: String,
        essayText: String,
        status: ReflectionReviewStatus = .open,
        submittedAt: Date? = nil,
        topicLabel: String? = nil,
        stepsCompleted: [BigKidReflectionStep] = []
    ) {
        self.reflectionId = reflectionId
        self.writingPrompt = writingPrompt
        self.essayText = essayText
        self.status = status
        self.submittedAt = submittedAt
        self.topicLabel = topicLabel
        self.stepsCompleted = stepsCompleted
    }

    enum CodingKeys: String, CodingKey {
        case reflectionId, writingPrompt, essayText, status, resolved
        case submittedAt, topicLabel, stepsCompleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reflectionId = try c.decode(UUID.self, forKey: .reflectionId)
        writingPrompt = try c.decode(String.self, forKey: .writingPrompt)
        essayText = try c.decode(String.self, forKey: .essayText)
        // Prefer the new tri-state field; fall back to legacy `resolved`
        // (true → .approved, false → .open) so any persisted history
        // payloads from before the tri-state migration still decode.
        if let s = try c.decodeIfPresent(ReflectionReviewStatus.self, forKey: .status) {
            status = s
        } else if try c.decodeIfPresent(Bool.self, forKey: .resolved) == true {
            status = .approved
        } else {
            status = .open
        }
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt)
        topicLabel = try c.decodeIfPresent(String.self, forKey: .topicLabel)
        stepsCompleted = try c.decodeIfPresent([BigKidReflectionStep].self, forKey: .stepsCompleted) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reflectionId, forKey: .reflectionId)
        try c.encode(writingPrompt, forKey: .writingPrompt)
        try c.encode(essayText, forKey: .essayText)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(submittedAt, forKey: .submittedAt)
        try c.encodeIfPresent(topicLabel, forKey: .topicLabel)
        try c.encode(stepsCompleted, forKey: .stepsCompleted)
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
    /// Posted by AuthService after sign-in (postAuth) and restore(). Carries
    /// `userInfo["account_id"]` (String UUID) so observers can scope their stores.
    static let evlinAccountSignedIn = Notification.Name("evlin.account.signedIn")

    /// DEBUG-only: emitted by the child-side pairing screen when the
    /// "Single-device testing? Switch to Parent" button is tapped.
    /// `OnboardingCoordinator` listens for this and jumps to the parent's
    /// `parentPairingCode` step so the same device can enter the code that
    /// was just generated. The pairing code itself is passed via the
    /// `evlin.dev.pendingPairingCode` UserDefaults key (cleared after read).
    static let evlinSingleDeviceJumpToParent =
        Notification.Name("evlinSingleDeviceJumpToParent")

    /// Posted after a chat-confirmed calendar mutation (event-exec 200) so the
    /// Calendar tab refetches instead of showing stale data.
    static let evlinCalendarInvalidated = Notification.Name("evlin.calendarInvalidated")
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    /// `var` (not `let`) so the streaming path can update a bubble's text
    /// in place as the typewriter engine reveals more of the buffered
    /// delta, instead of appending a new message each tick.
    var content: String
    let timestamp: Date
    var reasoning: String?
    var debugTurnID: String? = nil
    /// True for the client-injected tutorial seed message. Never archived,
    /// never sent to the backend as history context.
    var isSeed: Bool = false

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
    /// Target kind of the locked thing (app/category/list/all), so the receipt
    /// card renders a category/list glyph instead of an app artwork. Optional &
    /// defaulted so older persisted messages decode unchanged.
    var receiptTargetKind: NameIconKind? = nil

    // Agent envelope (Phase D/E — global AI copilot).
    // When AGENT_ENABLED=1, /parent/chat may return staged proposals
    // (parent must confirm) and/or executed receipts (with optional undo).
    // ChatView renders ProposalCard / ReceiptBubble beneath the bubble.
    var proposals: [ProposalDTO]? = nil
    var receipts: [ReceiptDTO]? = nil

    /// Big-kid: kid submitted reflection essay (`status=submitted`). Approve path = debug sheet.
    var reflectionSubmissionReview: ReflectionSubmissionReviewPayload? = nil

    var isStrategyArtifact: Bool { strategyTitle != nil }

    init(
        role: ChatRole,
        content: String,
        timestamp: Date = Date(),
        reasoning: String? = nil,
        action: ChatAction? = nil,
        debugTurnID: String? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.debugTurnID = debugTurnID
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
        QuickPrompt(icon: "shield", text: "Is my kid safe?"),
        QuickPrompt(icon: "moon", text: "Adjust bedtime strategy"),
        QuickPrompt(icon: "lock", text: "Lock phone for 30 min"),
    ]
}
