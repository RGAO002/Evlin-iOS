import SwiftUI

/// Renders the deterministic app-control cards (Task 11) in the Informed
/// Sentinel style. These are SEPARATE from the Brain/verb-table confirmation
/// cards (DangerConfirmCard / AmbiguityCard / …): those build from the legacy
/// `CardPayload`; this one renders the parsed `AppControlCardModel` straight
/// from the backend `card_payload` dict.
///
/// Two interaction shapes:
///  - Option cards (single_app_shield_advice, shield_token_missing,
///    app_not_found_terminal, category_rename_required, cannot_block_category,
///    category_shield_offer, catalog_app_inactive, bundle_id_required) render
///    `options` as full-width buttons → `onOption`.
///  - Disambiguation cards (app_store_disambiguation, child_disambiguation)
///    render `candidates` as selectable rows → `onCandidate`.
struct AppControlCard: View {
    let model: AppControlCardModel
    let onOption: (AppControlCardOption) -> Void
    let onCandidate: (AppControlCandidate) -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.body.isEmpty {
                Text(model.body)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDisambiguation {
                candidateList
            } else {
                optionButtons
            }

            if let onCancel {
                Button(action: onCancel) {
                    Text("Not now")
                        .font(.custom("Inter", size: 13).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.evSurfaceContainerLowest)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.evOutlineVariant, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
        .evShadow(.premium)
    }

    private var isDisambiguation: Bool {
        switch model.kind {
        case .appStoreDisambiguation, .childDisambiguation:
            return true
        default:
            return false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackground)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(iconForeground)
            }
            .frame(width: 40, height: 40)

            Text(model.title)
                .font(.custom("Manrope", size: 17).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    onOption(option)
                } label: {
                    Text(option.label)
                        .font(.custom("Inter", size: 14).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(index == 0 ? Color.white : Color.evOnSurface)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(index == 0 ? Color.evPrimary : Color.evSurfaceContainer)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(index == 0 ? Color.clear : Color.evOutlineVariant, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var candidateList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 {
                    Divider().overlay(Color.evOutlineVariant)
                }
                Button {
                    onCandidate(candidate)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.evPrimaryContainer)
                            Image(systemName: model.kind == .childDisambiguation ? "person.fill" : "app.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.evPrimary)
                        }
                        .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.display)
                                .font(.custom("Inter", size: 15).weight(.semibold))
                                .foregroundStyle(Color.evOnSurface)
                            if let bundle = candidate.bundleID, !bundle.isEmpty {
                                Text(bundle)
                                    .font(.custom("Inter", size: 11))
                                    .foregroundStyle(Color.evOutline)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.evOutline)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSurfaceContainerLow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    // MARK: - Per-kind iconography

    private var iconName: String {
        switch model.kind {
        case .singleAppShieldAdvice:  return "eye.slash.fill"
        case .shieldTokenMissing:     return "iphone.gen3.badge.exclamationmark"
        case .appStoreDisambiguation: return "questionmark.app.fill"
        case .appNotFoundTerminal:    return "magnifyingglass"
        case .childDisambiguation:    return "person.2.fill"
        case .categoryRenameRequired: return "pencil.and.list.clipboard"
        // Category block cards: the "cannot block" variant warns that a shield
        // is the only available lever; the "shield offer" variant proposes it.
        case .cannotBlockCategory:    return "nosign"
        case .categoryShieldOffer:    return "shield.lefthalf.filled"
        // Catalog/bundle cards point the parent at re-capturing the app, so an
        // informational badge fits.
        case .catalogAppInactive:     return "app.badge.checkmark"
        case .bundleIDRequired:       return "questionmark.app.dashed"
        }
    }

    private var iconBackground: Color {
        switch model.kind {
        case .appNotFoundTerminal, .shieldTokenMissing, .categoryRenameRequired,
             .cannotBlockCategory, .bundleIDRequired, .catalogAppInactive:
            return Color.evTertiaryContainer
        default:
            return Color.evPrimaryContainer
        }
    }

    private var iconForeground: Color {
        switch model.kind {
        case .appNotFoundTerminal, .shieldTokenMissing, .categoryRenameRequired,
             .cannotBlockCategory, .bundleIDRequired, .catalogAppInactive:
            return Color.evOnTertiaryContainer
        default:
            return Color.evPrimary
        }
    }
}
