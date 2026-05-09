//
//  QuestionCard.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.0 — Codable mirror of the backend question-card
//  schema. Used by QuestionCardAdapter (parses a PlanArchCardPayload with
//  kind="question.<style>" into a QuestionCard) and QuestionCardView.
//

import Foundation

struct QuestionOption: Codable, Hashable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

enum QuestionStyle: String, Codable {
    case singleChoice = "single_choice"
    case multiChoice = "multi_choice"
    case yesNo = "yes_no"
    case freeText = "free_text"
}

struct QuestionCard: Codable, Hashable, Identifiable {
    let questionId: String
    let prompt: String
    let style: QuestionStyle
    let options: [QuestionOption]
    let freeTextAllowed: Bool
    let cancellable: Bool

    var id: String { questionId }

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case prompt
        case style
        case options
        case freeTextAllowed = "free_text_allowed"
        case cancellable
    }
}

struct AnswerQuestionBody: Codable {
    let questionId: String
    let selectedValues: [String]
    let freeText: String?

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case selectedValues = "selected_values"
        case freeText = "free_text"
    }
}
