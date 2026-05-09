//
//  FeedbackService.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.4 — submit 👍/👎 feedback for an assistant turn
//  to /parent/chat/feedback.
//

import Foundation

struct FeedbackService {
    let baseURL: String
    let session: URLSession

    init(baseURL: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? APIClient().baseURL
        self.session = session
    }

    func submit(familyId: UUID, conversationId: UUID?, messageId: String,
                rating: ChatFeedbackRating, comment: String? = nil) async throws {
        let body = ChatFeedbackBody(
            familyId: familyId, conversationId: conversationId,
            messageId: messageId, rating: rating, comment: comment
        )
        guard let url = URL(string: "\(baseURL)/parent/chat/feedback") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await session.data(for: req)
    }
}
