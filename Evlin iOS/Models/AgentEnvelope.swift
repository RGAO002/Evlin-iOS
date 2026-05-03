import Foundation

// NOTE: `AnyCodable` already exists in Services/APIClient.swift (used for the
// rich ack-status `detail` payload). Reusing it here keeps a single
// type-erased value type across the codebase. Existing AnyCodable supports
// scalars (Int/Double/String/Bool) — sufficient for v1 tool args, which
// only surface a handful of well-known top-level keys (reason, title,
// minutes). Deeper nesting collapses to "" (acceptable for v1 display).

/// Tool-call confirmation pending parent approval.
/// Returned by /parent/chat when the agent stages a Proposal that the parent
/// must explicitly confirm before execution.
struct ProposalDTO: Codable, Sendable {
    let tool: String
    let args: [String: AnyCodable]
    let label: String
    let danger: String   // "low" | "medium" | "high"
    let token: String
}

/// Tool-call already executed by the agent (read-only or auto-approved).
/// Returned by /parent/chat for tool-calls the agent ran inline. Carries an
/// optional `undoToken` (server-side action id) used by the Undo button.
struct ReceiptDTO: Codable, Sendable {
    let tool: String
    let args: [String: AnyCodable]
    let summary: String
    /// Mutable so ChatViewModel can null it out after a successful undo —
    /// otherwise the ReceiptBubble would re-render the countdown button on
    /// every view rebuild (tab switch, scroll-back-into-view, etc).
    var undoToken: String?
    /// ISO8601 wall-clock deadline after which Undo is rejected. Used by
    /// ReceiptBubble to compute remaining seconds; without it the
    /// countdown resets every onAppear and lies about validity.
    let undoExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case tool, args, summary
        case undoToken = "undo_token"
        case undoExpiresAt = "undo_expires_at"
    }

    /// Seconds left until Undo expiry, computed from wall clock.
    /// Returns 0 if no token, no expiry timestamp, or already past.
    var undoSecondsRemaining: Int {
        guard undoToken != nil, let iso = undoExpiresAt else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: iso)
        }()
        guard let date else { return 0 }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }
}
