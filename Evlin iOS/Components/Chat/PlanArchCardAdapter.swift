//
//  PlanArchCardAdapter.swift
//  Evlin iOS
//
//  Task 23: Top-level dispatch by family prefix.
//  Returns nil when no adapter recognises the kind → ChatView uses
//  PlanArchCardView as a debug fallback.
//

import Foundation

/// Output of family adapters. ChatView wires `CardHandlers` separately
/// based on the payload's `source` and the user's button taps.
struct CardRenderModel {
    let cardID: CardID
    let context: CardContext
}

enum PlanArchCardAdapter {
    /// Returns nil if no family adapter recognises the kind. The caller
    /// (ChatView) then renders PlanArchCardView as a debug fallback.
    static func adapt(_ payload: PlanArchCardPayload, childName: String) -> CardRenderModel? {
        let parts = payload.kind.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "phone":      return PhoneCardAdapter.adapt(payload, childName: childName)
        case "reflection": return ReflectionCardAdapter.adapt(payload, childName: childName)
        case "task":       return TaskCardAdapter.adapt(payload, childName: childName)
        case "query":      return QueryCardAdapter.adapt(payload, childName: childName)
        case "event":      return EventCardAdapter.adapt(payload, childName: childName)
        default:           return nil
        }
    }
}
