//
//  EventTargetCardView.swift
//  Evlin iOS
//
//  P5 calendar-in-chat: self-rendering card for event.* / target.* kinds.
//  Rendered by ChatView's pendingPlanArchCard intercept (after
//  QuestionCardAdapter, before PlanArchCardAdapter). Actions are delegated to
//  ChatViewModel (AgentClient + 410 handling + next-card swap).
//
//  Styling: aligned to the app's ProposalCard/EvlinCard language — white
//  evSurface card, hairline border, glyph-chip header, system fonts. The
//  CALENDAR-specific kinds (result/create/bundle/disambiguation/scope) wear the
//  muted brick-red `evCalendar` accent; action buttons stay navy `evPrimary`
//  (the app-wide "do it" color). The target.* kinds are GLOBAL (shared with
//  lock/block device pick) so they render via TargetSelectView in neutral navy.
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

/// Local lifecycle for the create/bundle confirm button: tap → working → confirmed
/// (shown IN PLACE, no new card) or failed (buttons return + error line).
private enum CalendarConfirmState: Equatable { case idle, working, confirmed, failed }

/// Self-rendering card for event.* / target.* kinds. Actions are delegated to
/// ChatViewModel (which calls AgentClient + handles 410 + swaps the next card).
struct EventTargetCardView: View {
    let payload: PlanArchCardPayload
    let childName: String
    /// Tokens already consumed successfully (from ChatViewModel). @State dies
    /// on view rebuild (tab switch); without this the card re-offers Confirm
    /// for a single-use token that would 410.
    var confirmedTokens: Set<String> = []
    let onConfirm: (_ token: String) async -> String?
    let onPickEvent: (_ continuationToken: String, _ eventId: String, _ occurrenceStart: String) -> Void
    let onResolveTarget: (_ continuationToken: String, _ ids: [String]) -> Void
    let onReflection: (_ approve: Bool, _ note: String) async -> Void
    let onScope: (_ continuationToken: String) -> Void
    let onSkip: () -> Void

    @State private var confirmState: CalendarConfirmState = .idle
    @State private var confirmErrorText: String?

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

    // MARK: - Shared chrome (calendar identity = evCalendar red)

    private func glyphHeader(_ icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.evCalendar)
                .frame(width: 34, height: 34)
                .background(Color.evCalendarContainer,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.evOnSurface)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.subheadline).foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func primaryButton(_ title: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Color.evPrimary.opacity(enabled ? 1 : 0.35),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func neutralButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(Color.evOnSurface)
                .background(Color.evSurfaceContainer,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cardSurface<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.evSurfaceContainerLowest,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.evOutlineVariant.opacity(0.6), lineWidth: 1))
    }

    /// One list row: a red dot, the event title, and the occurrence time formatted
    /// to the device timezone. Reads `occurrence_start` (list) or `time` (bundle).
    private func eventRow(_ row: [String: Any]) -> some View {
        let title = (row["title"] as? String) ?? "Event"
        let start = (row["occurrence_start"] as? String) ?? (row["time"] as? String) ?? ""
        return HStack(spacing: 10) {
            Circle().fill(Color.evCalendar).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.evOnSurface)
                if !start.isEmpty {
                    Text(EventTargetDetail.displayDateTime(start))
                        .font(.caption).foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func groupedRows(_ rows: [[String: Any]]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                if idx > 0 { Divider().padding(.leading, 19) }
                eventRow(row)
            }
        }
        .background(Color.evSurfaceContainerLow,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - result (read-only; NO button)
    // Read-only receipt: a list result, or a "couldn't find" / "can't edit a
    // repeating event yet" notice. Intentionally has no dismiss button — it's
    // cleared when the parent sends their next message (sendMessage()) or replaced
    // by the next turn's cards, and in practice it is always the turn's only card.
    private var resultCard: some View {
        let rows = detail.rows("rows")
        return cardSurface {
            VStack(alignment: .leading, spacing: 12) {
                glyphHeader("calendar", title: payload.title, subtitle: payload.body)
                if !rows.isEmpty { groupedRows(rows) }
            }
        }
    }

    // MARK: - confirm (create + bundle)
    private var confirmCard: some View {
        let token = detail.string("proposal_token") ?? ""
        let isBundle = payload.kind == "event.bundle_confirm"
        return cardSurface {
            VStack(alignment: .leading, spacing: 12) {
                glyphHeader("calendar.badge.plus", title: payload.title,
                            subtitle: isBundle ? "Confirm to save all" : "Confirm to save")
                if isBundle {
                    groupedRows(detail.rows("rows"))
                } else {
                    createDetailBlock
                }
                conflictWarning
                confirmFooter(token: token, isBundle: isBundle)
            }
        }
    }

    /// Amber, non-blocking overlap warning (backend `conflicts`: same-person events
    /// that overlap this one). The parent can still Confirm — it's advisory.
    @ViewBuilder
    private var conflictWarning: some View {
        let conflicts = detail.rows("conflicts")
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                    Text(conflicts.count == 1 ? "Overlaps with an event"
                                              : "Overlaps with \(conflicts.count) events")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.evOnTertiaryContainer)
                ForEach(Array(conflicts.enumerated()), id: \.offset) { _, c in
                    let title = (c["title"] as? String) ?? "Event"
                    let start = (c["occurrence_start"] as? String) ?? ""
                    Text("• \(title)" + (start.isEmpty ? "" : " · \(EventTargetDetail.displayDateTime(start))"))
                        .font(.caption).foregroundStyle(Color.evOnTertiaryContainer)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.evTertiaryContainer,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Confirm/Skip → "Adding…" → "✓ Added to calendar" IN PLACE (no new card).
    /// Tapping Confirm runs onConfirm and flips the same card to a confirmed (or
    /// failed) state instead of dismissing it.
    @ViewBuilder
    private func confirmFooter(token: String, isBundle: Bool) -> some View {
        // A rebuilt view (tab switch) starts at .idle even when this token was
        // already consumed — render it confirmed instead of re-offering the
        // button (the token is single-use; a second tap 410s).
        let effectiveState: CalendarConfirmState =
            (confirmState == .idle && confirmedTokens.contains(token))
                ? .confirmed : confirmState
        switch effectiveState {
        case .confirmed:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.evSecondary)
                Text(isBundle ? "Added to calendar" : "Added to calendar")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.evSecondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        case .working:
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Adding…").font(.subheadline).foregroundStyle(Color.evOnSurfaceVariant)
                Spacer()
            }
            .padding(.vertical, 4)
        default:
            VStack(alignment: .leading, spacing: 8) {
                if confirmState == .failed {
                    Text(confirmErrorText ?? "Couldn't save — try again.")
                        .font(.caption).foregroundStyle(Color.evError)
                }
                HStack(spacing: 10) {
                    neutralButton("Skip", action: onSkip)
                    primaryButton(isBundle ? "Confirm all" : "Confirm",
                                  enabled: !token.isEmpty) {
                        Task {
                            confirmState = .working
                            confirmErrorText = nil
                            if let error = await onConfirm(token) {
                                confirmErrorText = error
                                confirmState = .failed
                            } else {
                                confirmState = .confirmed
                            }
                        }
                    }
                }
            }
        }
    }

    private var createDetailBlock: some View {
        let title = detail.string("title") ?? "Event"
        let start = detail.string("start_at_iso") ?? ""
        let end = detail.string("end_at_iso") ?? ""
        let names = detail.stringList("participant_names")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.evOnSurface)
            if !start.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 13))
                    Text(EventTargetDetail.displayDateRange(start: start, end: end))
                }
                .font(.subheadline).foregroundStyle(Color.evOnSurfaceVariant)
            }
            if !names.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person").font(.system(size: 13))
                    Text("For " + names.joined(separator: ", "))
                }
                .font(.subheadline).foregroundStyle(Color.evOnSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.evSurfaceContainerLow,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - disambiguation (pick which event)
    private var disambiguationCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        let options = detail.options("options")
        return cardSurface {
            VStack(alignment: .leading, spacing: 12) {
                glyphHeader("list.bullet.rectangle", title: payload.title, subtitle: payload.body)
                VStack(spacing: 8) {
                    ForEach(options) { opt in
                        Button {
                            // option id == event_id; pass occurrence_start so event-select
                            // can re-verify it belongs to the expanded event (§6.4).
                            onPickEvent(ct, opt.id, opt.occurrenceStart)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(opt.label).font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.evOnSurface)
                                    if !opt.occurrenceStart.isEmpty {
                                        Text(EventTargetDetail.displayDateTime(opt.occurrenceStart))
                                            .font(.caption).foregroundStyle(Color.evOnSurfaceVariant)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.evOutline)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .background(Color.evSurfaceContainerLow,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                neutralButton("Cancel", action: onSkip)
            }
        }
    }

    // MARK: - scope (recurring whole-series confirm)
    private var scopeCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        return cardSurface {
            VStack(alignment: .leading, spacing: 12) {
                glyphHeader("repeat", title: payload.title, subtitle: nil)
                if let b = payload.body, !b.isEmpty {
                    Text(b)
                        .font(.subheadline).foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.evSurfaceContainerLow,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 10) {
                    neutralButton("Cancel", action: onSkip)
                    primaryButton("Whole series") { onScope(ct) }
                }
            }
        }
    }

    // MARK: - target (GLOBAL — neutral navy, shared with lock/block)
    private var targetCard: some View {
        let ct = detail.string("continuation_token") ?? ""
        let groups = !detail.groups("groups").isEmpty
            ? detail.groups("groups")
            : [TargetGroup(id: "flat", childName: "", options: detail.options("options"))]
        return TargetSelectView(
            title: payload.title,
            groups: groups,
            allowsMultiple: payload.kind != "target.device_select",
            onConfirm: { ids in onResolveTarget(ct, ids) }, onCancel: onSkip)
    }

    // MARK: - reflection (unchanged — reuses the existing review card)
    private var reflectionCard: some View {
        ReflectionSubmissionReviewCard(
            childName: childName,
            writingPrompt: detail.string("summary") ?? "",
            essayText: detail.string("essay_excerpt") ?? "",
            status: .open,
            onApprove: { note in await onReflection(true, note) },
            onRedo: { note in await onReflection(false, note) })
    }
}
