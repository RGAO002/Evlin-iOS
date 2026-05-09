//
//  Memory.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.1 — Codable models for the long-term memory
//  surface. List/CRUD endpoints under /parent/memory.
//

import Foundation

enum MemoryCategory: String, Codable, CaseIterable, Identifiable {
    case preference, family_fact, rule, pattern, decision
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .preference: return "Preferences"
        case .family_fact: return "Family Facts"
        case .rule: return "Rules"
        case .pattern: return "Patterns"
        case .decision: return "Past Decisions"
        }
    }
}

enum MemorySource: String, Codable {
    case ai_inferred, ai_from_parent_statement, user_added, user_edited
}

struct Memory: Codable, Identifiable, Hashable {
    let id: UUID
    let familyId: UUID
    let childId: UUID?
    let category: MemoryCategory
    let text: String
    let source: MemorySource
    let createdAt: Date
    let lastSeenAt: Date
    let userLocked: Bool
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case childId = "child_id"
        case category
        case text
        case source
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case userLocked = "user_locked"
        case confidence
    }
}

struct MemoryCreateBody: Codable {
    let familyId: UUID
    let childId: UUID?
    let category: MemoryCategory
    let text: String
    enum CodingKeys: String, CodingKey {
        case familyId = "family_id", childId = "child_id", category, text
    }
}

struct MemoryUpdateBody: Codable {
    let text: String
    let category: MemoryCategory?
}
