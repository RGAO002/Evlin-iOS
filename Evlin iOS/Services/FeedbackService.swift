//
//  FeedbackService.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.4 — submit 👍/👎 feedback for an assistant turn
//  to /parent/chat/feedback.
//
//  B4: routes through APIClient.authedRequest/authedData (Bearer + 401 refresh).
//  family_id is still included in the body for backwards compat with older
//  server builds; the backend now ignores it (derives family from Bearer token).
//

import Foundation

struct FeedbackService {
    let client: APIClient

    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func submit(conversationId: UUID?, messageId: String,
                rating: ChatFeedbackRating, comment: String? = nil) async throws {
        let body = ChatFeedbackBodyB4(
            conversationId: conversationId,
            messageId: messageId, rating: rating, comment: comment
        )
        var req = client.authedRequest(path: "/parent/chat/feedback", method: "POST")
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await client.authedData(for: req)
    }
}

/// Feedback body for B4+: family_id dropped (server derives it from Bearer token).
private struct ChatFeedbackBodyB4: Codable {
    let conversationId: UUID?
    let messageId: String
    let rating: ChatFeedbackRating
    let comment: String?
    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case rating
        case comment
    }
}
