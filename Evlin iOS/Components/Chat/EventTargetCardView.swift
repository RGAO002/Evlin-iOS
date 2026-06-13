//
//  EventTargetCardView.swift
//  Evlin iOS
//
//  P5 calendar-in-chat: self-rendering card for event.* / target.* kinds.
//  Rendered by ChatView's pendingPlanArchCard intercept (after
//  QuestionCardAdapter, before PlanArchCardAdapter). Actions are delegated to
//  ChatViewModel (AgentClient + 410 handling + next-card swap).
//

import SwiftUI

enum EventTargetRoute: Equatable {
    case result, confirm, disambiguation, targetSelect, reflection, scope
    init?(kind: String) {
        switch kind {
        case "event.result": self = .result
        case "event.create_confirm", "event.bundle_confirm": self = .confirm
        case "event.disambiguation": self = .disambiguation
        case "event.reflection_review_pending": self = .reflection
        case "event.scope": self = .scope
        case let k where k.hasPrefix("target."): self = .targetSelect
        default: return nil
        }
    }
}

/// Self-rendering card for event.* / target.* kinds. Actions are delegated to
/// ChatViewModel (which calls AgentClient + handles 410 + swaps the next card).
struct EventTargetCardView: View {
    let payload: PlanArchCardPayload
    let childName: String
    let onConfirm: (_ token: String) -> Void
    let onPickEvent: (_ continuationToken: String, _ eventId: String, _ occurrenceStart: String) -> Void
    let onResolveTarget: (_ continuationToken: String, _ ids: [String]) -> Void
    let onReflection: (_ approve: Bool, _ note: String) async -> Void
    let onScope: (_ continuationToken: String) -> Void
    let onSkip: () -> Void

    private var detail: EventTargetDetail { EventTargetDetail(payload.detail) }

    var body: some View {
        switch EventTargetRoute(kind: payload.kind) {
        case .result:        resultCard
        case .confirm:       confirmCard
        case .disambiguation: disambiguationCard
        case .targetSelect:  targetCard
        case .reflection:    reflectionCard
        case .scope:         scopeCard
        case .none:          EmptyView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.title).font(.headline)
            if let b = payload.body, !b.isEmpty { Text(b).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private var resultCard: some View {
        // event.result is a read-only receipt (list results + "couldn't find" /
        // "can't edit a repeating event yet" notices). It MUST render detail.rows
        // (list events) and carry a Done button — otherwise it pins on screen and
        // stalls the pendingPlanArchCard queue (code-review finding #2).
        let rows = detail.rows("rows")
        return VStack(alignment: .leading, spacing: 8) {
            header
            if !rows.isEmpty {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text((row["title"] as? String) ?? "Event").font(.subheadline)
                        Spacer()
                        if let t = row["occurrence_start"] as? String, !t.isEmpty {
                            Text(t).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done", action: onSkip).buttonStyle(.bordered) }
        }
        .padding(16)
        .background(Color(.systemBackground)).cornerRadius(12)
    }

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack {
                Button("Skip", action: onSkip).buttonStyle(.bordered)
                Spacer()
                Button("Confirm") { onConfirm(detail.string("proposal_token") ?? "") }
                    .buttonStyle(.borderedProminent)
                    .disabled((detail.string("proposal_token") ?? "").isEmpty)
            }
        }.padding(16).background(Color(.systemBackground)).cornerRadius(12)
    }

    private var disambiguationCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(detail.options("options")) { opt in
                Button(opt.label) {
                    // option id == event_id; pass the emitted occurrence_start so
                    // event-select can re-verify it belongs to the expanded event (§6.4).
                    onPickEvent(ct, opt.id, opt.occurrenceStart)
                }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
            Button("Cancel", action: onSkip).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(16).background(Color(.systemBackground)).cornerRadius(12)
    }

    private var targetCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        let groups = !detail.groups("groups").isEmpty
            ? detail.groups("groups")
            : [TargetGroup(id: "flat", childName: "", options: detail.options("options"))]
        return TargetSelectView(title: payload.title, groups: groups,
            onConfirm: { ids in onResolveTarget(ct, ids) }, onCancel: onSkip)
    }

    private var scopeCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            header
            HStack {
                Button("Cancel", action: onSkip).buttonStyle(.bordered)
                Spacer()
                Button("Whole series") { onScope(ct) }.buttonStyle(.borderedProminent)
            }
        }.padding(16).background(Color(.systemBackground)).cornerRadius(12)
    }

    private var reflectionCard: some View {
        // Preserve render + act (§2 item 2 / §11): route to the existing card.
        ReflectionSubmissionReviewCard(
            childName: childName,
            writingPrompt: detail.string("summary") ?? "",
            essayText: detail.string("essay_excerpt") ?? "",
            status: .open,
            onApprove: { note in await onReflection(true, note) },
            onRedo: { note in await onReflection(false, note) })
    }
}
