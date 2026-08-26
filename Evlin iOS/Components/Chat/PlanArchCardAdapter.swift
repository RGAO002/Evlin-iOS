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

// MARK: - Template-button action bridge

/// Wires a plan-arch card's OWN backend-authored options onto the polished
/// template's primary/secondary buttons.
///
/// The handler factory used to leave `onPrimary`/`onSecondary` nil for every
/// adapted kind, on the theory that "polished cards drive their own primary
/// action". Five templates (A1, A3, B1, E1, F1) never did — their builders
/// render `h.onPrimary ?? {}`, so the confirm button drew fine and did
/// NOTHING (Esen, 2026-08-21: "the buttons do nothing and only Cancel
/// works"). The old alternative — synthesising an `intent_confirmed` patch —
/// really was rejected by the backend (`extra="forbid"`); forwarding the
/// card's own options has no such problem: the patch bytes are
/// backend-authored, exactly what the fallback `PlanArchCardView` sends.
///
/// Mapping is positional over the non-cancel options: first → primary,
/// second → secondary. Kinds whose templates are driven by dedicated
/// handlers (D1 durations, U1 pickers, reflection cards) are excluded.
nonisolated enum PlanArchTemplateActionBridge {
    /// Card IDs whose builder consumes `onPrimary` (and possibly
    /// `onSecondary`) as its main actions.
    static let templateDrivenCardIDs: Set<CardID> = [.A1, .A3, .B1, .E1, .F1]

    struct Wiring: Equatable {
        let primary: PlanArchCardOption
        let secondary: PlanArchCardOption?
    }

    static func wiring(
        for payload: PlanArchCardPayload,
        childName: String
    ) -> Wiring? {
        guard let model = PlanArchCardAdapter.adapt(payload, childName: childName),
              templateDrivenCardIDs.contains(model.cardID)
        else { return nil }
        let actionable = payload.options.filter { !$0.cancelsPlan }
        guard let primary = actionable.first else { return nil }
        return Wiring(
            primary: primary,
            secondary: actionable.count > 1 ? actionable[1] : nil
        )
    }
}
