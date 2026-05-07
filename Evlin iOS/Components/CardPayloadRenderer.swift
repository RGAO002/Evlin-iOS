//
//  CardPayloadRenderer.swift
//  Evlin iOS
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
            Text(card.title)
                .font(.headline)
                .multilineTextAlignment(.leading)

            if let body = card.body {
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
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else if card.type == .unlockPicker {
                unlockPickerBody
            } else {
                // Standard options: render each as a button.
                ForEach(card.options) { opt in
                    optionButton(opt)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
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
        Button {
            onOption(opt)
        } label: {
            Text(opt.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(opt.cancelsPlan ? Color.gray.opacity(0.2) : Color.blue.opacity(0.1))
                .foregroundStyle(opt.cancelsPlan ? Color.secondary : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
