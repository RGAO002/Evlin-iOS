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
    let undoToken: String?

    enum CodingKeys: String, CodingKey {
        case tool, args, summary
        case undoToken = "undo_token"
    }
}
