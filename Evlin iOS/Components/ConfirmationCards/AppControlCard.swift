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
    @State private var selectedRestrictionIDs: Set<String> = []

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
                if !model.options.isEmpty {
                    optionButtons
                }
            } else if model.kind == .restrictionUnlockPicker {
                restrictionUnlockContent
            } else if model.kind == .lockSelectedAppsConfirm {
                lockConfirmContent
                optionButtons
            } else {
                optionButtons
            }

            if let onCancel, model.kind != .restrictionUnlockPicker {
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
        .onAppear {
            if model.kind == .restrictionUnlockPicker, selectedRestrictionIDs.isEmpty {
                selectedRestrictionIDs = Set(model.restrictionGroups.flatMap { $0.sessions.map(\.id) })
            }
        }
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
                        CandidateIcon(
                            url: model.kind == .childDisambiguation ? candidate.childAvatarURL : candidate.artworkURL,
                            systemName: model.kind == .childDisambiguation ? "person.fill" : "app.fill",
                            fallbackText: model.kind == .childDisambiguation ? (candidate.childAvatarValue ?? String(candidate.display.prefix(1)).uppercased()) : nil,
                            fallbackColorHex: model.kind == .childDisambiguation ? candidate.childAvatarColorHex : nil,
                            circular: model.kind == .childDisambiguation
                        )
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

    @ViewBuilder
    private var restrictionUnlockContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.restrictionGroups, id: \.id) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        restrictionGroupAvatar(group)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.childName)
                                .font(.custom("Manrope", size: 16).weight(.heavy))
                                .foregroundStyle(Color.evOnSurface)
                            Text(group.deviceSummary.isEmpty ? restrictionCountLabel(group.sessions.count) : "\(group.deviceSummary) · \(restrictionCountLabel(group.sessions.count))")
                                .font(.custom("Inter", size: 12))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            let ids = group.sessions.map(\.id)
                            let currentlyAllSelected = ids.allSatisfy { selectedRestrictionIDs.contains($0) }
                            if currentlyAllSelected {
                                selectedRestrictionIDs.subtract(ids)
                            } else {
                                selectedRestrictionIDs.formUnion(ids)
                            }
                        } label: {
                            Text(group.sessions.allSatisfy { selectedRestrictionIDs.contains($0.id) } ? "Selected" : "Select")
                                .font(.custom("Inter", size: 12).weight(.bold))
                                .foregroundStyle(Color.evPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.evPrimaryContainer))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 8) {
                        ForEach(group.sessions) { row in
                            restrictionRow(row)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.evSurfaceContainerLow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1)
                )
            }

            HStack(spacing: 9) {
                Button {
                    onOption(AppControlCardOption(action: "cancel", label: "Cancel", forceConfirmations: []))
                } label: {
                    Text("Cancel")
                        .font(.custom("Inter", size: 14).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(Color.evOnSurface)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.evSurfaceContainer)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    guard let token = model.pickerToken, !selectedRestrictionIDs.isEmpty else { return }
                    let selected = model.restrictionGroups
                        .flatMap(\.sessions)
                        .map(\.id)
                        .filter { selectedRestrictionIDs.contains($0) }
                    let marker = "restriction_unlock:\(token):selected:\(selected.joined(separator: ","))"
                    onOption(AppControlCardOption(
                        action: "restriction_unlock_selected",
                        label: "Remove selected",
                        forceConfirmations: [marker]
                    ))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open.fill")
                        Text("Remove selected")
                    }
                    .font(.custom("Inter", size: 14).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(Color.white)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(selectedRestrictionIDs.isEmpty ? Color.evOutline : Color.evPrimary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedRestrictionIDs.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func restrictionGroupAvatar(_ group: RestrictionUnlockGroup) -> some View {
        let size: CGFloat = 38
        if let url = group.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    restrictionAvatarFallback(group)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            restrictionAvatarFallback(group)
                .frame(width: size, height: size)
        }
    }

    private func restrictionAvatarFallback(_ group: RestrictionUnlockGroup) -> some View {
        let base = color(from: group.avatarColorHex) ?? Color.evPrimary
        let raw = group.avatarValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? String(group.childName.prefix(1)).uppercased() : raw
        return ZStack {
            Circle().fill(base.opacity(0.16))
            Text(text)
                .font(.custom("Manrope", size: 15).weight(.heavy))
                .foregroundStyle(base)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    private func restrictionCountLabel(_ count: Int) -> String {
        "\(count) active restriction\(count == 1 ? "" : "s")"
    }

    private func restrictionRow(_ row: RestrictionUnlockRow) -> some View {
        let isSelected = selectedRestrictionIDs.contains(row.id)
        return Button {
            if isSelected {
                selectedRestrictionIDs.remove(row.id)
            } else {
                selectedRestrictionIDs.insert(row.id)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.evPrimary : Color.evSurfaceContainerLowest)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(isSelected ? Color.evPrimary : Color.evOutline, lineWidth: 1.5)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.custom("Inter", size: 14).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                        .lineLimit(1)
                    Text(row.subtitle.isEmpty ? row.deviceLabel : "\(row.subtitle) · \(row.deviceLabel)")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(row.badge)
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(row.action == "unblock" ? Color.orange : Color.evPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill((row.action == "unblock" ? Color.orange : Color.evPrimary).opacity(0.12)))
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.evPrimaryContainer.opacity(0.42) : Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.evPrimary.opacity(0.24) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func color(from hex: String?) -> Color? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let value = UInt(raw, radix: 16) else {
            return nil
        }
        return Color(hex: value)
    }

    // MARK: - Lock-selected-apps confirm content

    /// App icon tiles + category chips shown only for `.lockSelectedAppsConfirm`.
    @ViewBuilder
    private var lockConfirmContent: some View {
        // ── Apps section ──────────────────────────────────────────────────
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps · \(model.appsCount)")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)

            let maxTiles = 6
            let preview = model.appPreview
            let overflow = model.appsCount - min(preview.count, maxTiles)
            HStack(spacing: 6) {
                ForEach(Array(preview.prefix(maxTiles).enumerated()), id: \.offset) { _, item in
                    AppPreviewTile(
                        artworkURL: item.artworkURL,
                        displayName: item.displayName
                    )
                }
                if overflow > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.evSurfaceContainerLow)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.evOutlineVariant, lineWidth: 1)
                            )
                        Text("+\(overflow)")
                            .font(.custom("Inter", size: 12).weight(.bold))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                    .frame(width: 38, height: 38)
                }
            }
        }

        // ── Categories section ────────────────────────────────────────────
        if !model.categoryPreview.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Categories · \(model.categoriesCount)")
                    .font(.custom("Inter", size: 12).weight(.semibold))
                    .foregroundStyle(Color.evOnSurfaceVariant)

                // Wrap chips into a flowing horizontal layout.
                // SwiftUI doesn't have a built-in wrap layout pre-iOS 16,
                // but chips are few (≤8 from backend) so a simple HStack
                // that allows truncation is acceptable; the brief only
                // specifies a horizontal row of chips.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.categoryPreview, id: \.self) { name in
                            CategoryChip(name: name)
                        }
                    }
                }
            }
        }
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
        // Task 6 — lock-selected-apps confirmation cards.
        case .lockSelectedAppsConfirm: return "checkmark.shield.fill"
        case .lockSelectedAppsEmpty:   return "shield.slash"
        case .restrictionUnlockPicker: return "lock.open.fill"
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

// MARK: - App Preview Tile

/// A 38×38 rounded-square app icon tile for the lock-confirm card preview row.
/// Resolves artwork via the backend URL when available; falls back to an iTunes
/// lookup by display name via `AppArtworkResolver`, then to an SF Symbol.
private struct AppPreviewTile: View {
    let artworkURL: URL?
    let displayName: String

    @State private var resolvedURL: URL? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.evPrimaryContainer)

            if let url = artworkURL ?? resolvedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipped()
                    default:
                        fallbackIcon
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                fallbackIcon
            }
        }
        .frame(width: 38, height: 38)
        .task(id: displayName) {
            guard artworkURL == nil, resolvedURL == nil else { return }
            resolvedURL = await AppArtworkResolver.shared.artwork(forName: displayName)
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "app.fill")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.evPrimary)
    }
}

// MARK: - Category Chip

/// A pill-shaped chip showing an SF Symbol + category name.
/// Used in the lock-confirm card's categories section.
private struct CategoryChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: NameWithIcon.categorySymbol(for: name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.evPrimary)
            Text(name)
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurface)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.evSurfaceContainerLow)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }
}

// MARK: - Candidate Icon

private struct CandidateIcon: View {
    let url: URL?
    let systemName: String
    var fallbackText: String? = nil
    var fallbackColorHex: String? = nil
    var circular: Bool = false

    var body: some View {
        if circular {
            content
                .background(Circle().fill(fallbackBase.opacity(0.16)))
                .clipShape(Circle())
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.evPrimaryContainer)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var fallbackBase: Color {
        color(from: fallbackColorHex) ?? Color.evPrimaryContainer
    }

    @ViewBuilder
    private var content: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let fallbackText, !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(fallbackText)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .foregroundStyle(color(from: fallbackColorHex) ?? Color.evPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.evPrimary)
        }
    }

    private func color(from hex: String?) -> Color? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let value = UInt(raw, radix: 16) else {
            return nil
        }
        return Color(hex: value)
    }
}
