import Foundation

/// Sanitized, serialisable snapshot of a `ChatMessage` suitable for
/// durable storage in `ChatHistoryStore`.
///
/// All live command / receipt tracking state (`commandID`, `receiptState`,
/// `proposals`, `receipts`) is stripped on creation.  Any non-nil
/// `receiptState` that was present is frozen into the human-readable
/// `receiptSummary` string so the UI can still show "Queued" / "Done" etc.
/// without re-opening a poll.
///
/// `asInertChatMessage()` reconstructs a render-only `ChatMessage` with
/// `commandID == nil` and `receiptState` either `.nil` or a terminal value,
/// which guarantees it can never satisfy the
/// `ChatViewModel.resumePendingAckPolls` guard
/// (`role == .agent && receiptState == .pending && commandID != nil`).
struct StoredChatMessage: Codable, Equatable {
    let role: ChatRole
    let content: String
    let timestamp: Date
    /// Human-readable summary of the receipt state at the time the message
    /// was archived.  `nil` when the original message never had a receipt
    /// (parent messages, agent messages without a command, etc.).
    let receiptSummary: String?

    // MARK: - Init

    init(sanitizing live: ChatMessage) {
        self.role = live.role
        self.content = live.content
        self.timestamp = live.timestamp
        self.receiptSummary = live.receiptState.map { StoredChatMessage.summary(for: $0) }
    }

    // MARK: - Reconstruction

    /// Rebuilds a render-only `ChatMessage` that can NEVER satisfy the
    /// `resumePendingAckPolls` guard.
    ///
    /// Guarantee: `commandID == nil` (stripped) AND `receiptState != .pending`
    /// (either `nil` when there was no receipt, or `.kidNotResponding` as a
    /// safe terminal placeholder when a receipt summary exists).
    func asInertChatMessage() -> ChatMessage {
        var msg = ChatMessage(role: role, content: content, timestamp: timestamp)
        // commandID is intentionally left nil (default) — this is the primary
        // guard against re-triggering ack polling.
        // receiptState: use kidNotResponding (terminal) only when a frozen
        // receipt summary exists, so the UI can still render something.
        if receiptSummary != nil {
            msg.receiptState = .kidNotResponding
        }
        // proposals, receipts, reflectionSubmissionReview etc. are all nil by
        // default — live card state is never restored from stored messages.
        return msg
    }

    // MARK: - Private helpers

    private static func summary(for state: ReceiptState) -> String {
        switch state {
        case .pending:
            return "Queued"
        case .confirmedExact(let verb, let displayName, _, _):
            return "\(verb) \(displayName)"
        case .confirmedFallback(let verb, let displayName, _, _):
            return "\(verb) \(displayName)"
        case .failedPermission:
            return "Failed (permission)"
        case .failedListNotFound(let listName):
            return "Failed (list not found: \(listName))"
        case .failedCategoryNotConfigured(let category):
            return "Failed (category not configured: \(category))"
        case .failedAppNotConfigured(let appReference):
            return "Failed (app not configured: \(appReference))"
        case .failedTimeout:
            return "Failed (timeout)"
        case .kidNotResponding:
            return "Kid not responding"
        case .pickedUp:
            return "Picked up"
        case .failedOther(let reason):
            return "Failed: \(reason)"
        }
    }
}
