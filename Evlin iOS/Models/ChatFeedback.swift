//
//  ChatFeedback.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.2 — Codable models for the 👍/👎 feedback POST
//  to /parent/chat/feedback.
//

import Foundation

enum ChatFeedbackRating: String, Codable {
    case thumbsUp = "thumbs_up"
    case thumbsDown = "thumbs_down"
}

struct ChatFeedbackBody: Codable {
    let familyId: UUID
    let conversationId: UUID?
    let messageId: String
    let rating: ChatFeedbackRating
    let comment: String?
    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case rating
        case comment
    }
}
