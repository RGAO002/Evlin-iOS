//
//  CardPayloadRenderer.swift
//  Evlin iOS
//
//  Phase 2A: PlanArchCardView is now a DEBUG FALLBACK only. Every known
//  CardPayload kind must route through PlanArchCardAdapter →
//  CardDispatcher. This view renders only when the adapter returns nil
//  (unknown / future kind). Spec §1 acceptance.
//
//  Plan-arch dual-path renderer: dispatches on PlanArchCardType to render
//  one of 8 templates. Phase 1 uses a unified option-list layout
//  for all card types; Phase 2 may add per-type custom views.
//

import SwiftUI

struct PlanArchCardView: View {
    let card: PlanArchCardPayload
    /// Called when the parent taps an option. The renderer surfaces
    /// the chosen PlanArchCardOption + cancels_plan flag; ChatViewModel handles
    /// the patch round-trip via PlanPatchClient.
    let onOption: (PlanArchCardOption) -> Void
    /// For lazy_tag specifically: called when the parent should be
    /// driven into FamilyActivityPicker. ChatViewModel wires this up.
    let onLazyTag: ((PlanArchCardPayload) -> Void)?
    @State private var selectedUnlockOptionIDs: Set<UUID> = []

    init(card: PlanArchCardPayload,
         onOption: @escaping (PlanArchCardOption) -> Void,
         onLazyTag: ((PlanArchCardPayload) -> Void)? = nil) {
        self.card = card
        self.onOption = onOption
        self.onLazyTag = onLazyTag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: icon + title (mirrors DangerConfirmCard / other polished cards)
            HStack(spacing: 8) {
                Image(systemName: iconForKind(card.kind))
                    .font(.title2)
                    .foregroundStyle(iconTintForKind(card.kind))
                Text(card.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
            }

            if let body = card.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            // lazy_tag CardType: render a single "Pick the app" CTA that
            // drives into FamilyActivityPicker; CustomTokenPickerView
            // handles the rest.
            if card.type == .lazyTag {
                Button {
                    onLazyTag?(card)
                } label: {
                    Text("Pick the app")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            } else if card.type == .unlockPicker {
                unlockPickerBody
            } else {
                // Standard options: render each as a styled button.
                VStack(spacing: 8) {
                    ForEach(card.options) { opt in
                        optionButton(opt)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 6)
        .overlay(alignment: .topTrailing) {
            if card.danger == .high {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(8)
            } else if card.danger == .medium {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
    }

    /// Pick an SF Symbol from the card's kind. Generic icons that signal
    /// what kind of action the card represents — keeps the visual cue
    /// consistent across the polished + fallback paths.
    private func iconForKind(_ kind: String?) -> String {
        guard let kind else { return "questionmark.circle" }
        if kind.hasPrefix("phone.") {
            if kind.contains("unlock") || kind.contains("unshield") { return "lock.open.fill" }
            if kind.contains("danger") || kind.contains("permanent") { return "exclamationmark.shield.fill" }
            return "lock.shield.fill"
        }
        if kind.hasPrefix("reflection.") {
            if kind.contains("cancel") { return "arrow.uturn.backward.circle" }
            if kind.contains("approve") || kind.contains("redo") { return "checkmark.seal" }
            if kind.contains("failed") { return "exclamationmark.triangle" }
            return "brain.head.profile"
        }
        if kind.hasPrefix("task.") {
            return "checklist"
        }
        if kind.hasPrefix("query.") {
            return "magnifyingglass"
        }
        if kind.hasPrefix("question.") {
            return "questionmark.bubble"
        }
        return "info.circle"
    }

    private func iconTintForKind(_ kind: String?) -> Color {
        guard let kind else { return .accentColor }
        if kind.hasPrefix("phone.") { return Color.accentColor }
        if kind.hasPrefix("reflection.") { return Color.purple }
        if kind.hasPrefix("task.") { return Color.green }
        if kind.hasPrefix("query.") { return Color.gray }
        return .accentColor
    }

    @ViewBuilder
    private var unlockPickerBody: some View {
        let unlockOptions = card.options.filter { !$0.cancelsPlan && !$0.isUnlockEverything }
        let everythingOption = card.options.first(where: { $0.isUnlockEverything })
        let cancelOption = card.options.first(where: { $0.cancelsPlan })

        if unlockOptions.count <= 1 {
            ForEach(card.options) { opt in optionButton(opt) }
        } else {
            VStack(spacing: 10) {
                ForEach(unlockOptions) { opt in
                    Button {
                        if selectedUnlockOptionIDs.contains(opt.id) {
                            selectedUnlockOptionIDs.remove(opt.id)
                        } else {
                            selectedUnlockOptionIDs.insert(opt.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedUnlockOptionIDs.contains(opt.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(selectedUnlockOptionIDs.contains(opt.id) ? .blue : .secondary)
                            Text(opt.label)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    let selected = unlockOptions.filter { selectedUnlockOptionIDs.contains($0.id) }
                    guard !selected.isEmpty else { return }
                    onOption(PlanArchCardOption.unlockSelected(selected))
                } label: {
                    Text("Unlock selected")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(selectedUnlockOptionIDs.isEmpty ? Color.gray.opacity(0.2) : Color.blue)
                        .foregroundStyle(selectedUnlockOptionIDs.isEmpty ? Color.secondary : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(selectedUnlockOptionIDs.isEmpty)

                if let everythingOption {
                    optionButton(everythingOption)
                }
                if let cancelOption {
                    optionButton(cancelOption)
                }
            }
        }
    }

    private func optionButton(_ opt: PlanArchCardOption) -> some View {
        let style = buttonStyle(for: opt)
        return Button {
            onOption(opt)
        } label: {
            Text(opt.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(backgroundColor(for: style))
                .foregroundColor(foregroundColor(for: style))
                .cornerRadius(10)
        }
    }

    /// Pick a button style from the option's role. Same vocabulary as
    /// DangerConfirmCard / other polished cards — keeps the look unified.
    private enum OptionStyle { case primary, destructive, cancel, secondary }

    private func buttonStyle(for opt: PlanArchCardOption) -> OptionStyle {
        if opt.cancelsPlan { return .cancel }
        let lower = opt.label.lowercased()
        // "Unlock everything", "Block X permanently", "Delete X" — destructive intent.
        if lower.contains("unlock everything")
            || lower.contains("permanently")
            || lower.starts(with: "block ")
            || lower.starts(with: "delete ")
            || lower.contains("remove all")
        {
            return .destructive
        }
        return .primary
    }

    private func backgroundColor(for style: OptionStyle) -> Color {
        switch style {
        case .primary:     return .accentColor
        case .destructive: return .red
        case .secondary:   return Color(.systemGray5)
        case .cancel:      return Color(.systemGray6)
        }
    }

    private func foregroundColor(for style: OptionStyle) -> Color {
        switch style {
        case .primary, .destructive: return .white
        default: return .primary
        }
    }
}

private extension PlanArchCardOption {
    var isUnlockEverything: Bool {
        guard let target = patch["target"]?.value as? [String: Any],
              let kind = target["kind"] as? String else { return false }
        return kind == "all"
    }

    static func unlockSelected(_ options: [PlanArchCardOption]) -> PlanArchCardOption {
        let targets = options.compactMap { opt -> [String: Any]? in
            opt.patch["target"]?.value as? [String: Any]
        }
        return PlanArchCardOption(
            label: "Unlock selected",
            patch: ["selected_targets": PlanArchAnyCodable(targets)]
        )
    }
}
