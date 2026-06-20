import SwiftUI
import FamilyControls
import ManagedSettings

// MARK: - Prototype-matched palette (app-controls-v2-prototype.html)
//
// The prototype lives in a warm-neutral palette that has no direct `Color.ev*`
// equivalent, so — exactly as `MatchedChip` already does for `#15803D`/`#DCFCE7`
// — these mirror the prototype's CSS custom properties as literal hex. Scoped to
// this screen so the global tokens are untouched.
private extension Color {
    static let evPageBg     = Color(hex: 0xE9E7E0) // --color-background-tertiary
    static let evTrayFill   = Color(hex: 0xF3F1EC) // --color-background-secondary
    static let evCardFill   = Color(hex: 0xFFFFFF) // --color-background-primary
    static let evHairline   = Color.black.opacity(0.12) // --color-border-tertiary
    static let evHairlineStrong = Color.black.opacity(0.22) // --color-border-secondary
    static let evTextPrimary   = Color(hex: 0x1B1B19) // --color-text-primary
    static let evTextSecondary = Color(hex: 0x5F5E5A) // --color-text-secondary
    static let evTextTertiary  = Color(hex: 0x908F86) // --color-text-tertiary
    static let evTextDanger    = Color(hex: 0xA32D2D) // --color-text-danger
    // The prototype's open/active accent is a bright green (#16A34A), NOT navy.
    static let evAccentGreen   = Color(hex: 0x16A34A)
    static let evAccentGreenSoft = Color(hex: 0x16A34A).opacity(0.06)
}

/// App Controls v2 screen — Tasks 3.2 + 3.4 (accordion inline bind + upload-on-bind).
///
/// Replicates the `app-controls-v2-prototype.html` "App Controls v2" layout:
/// header "App Controls" + an "Add" button, a subtitle, then a **Categories**
/// section ON TOP (all rows shown) and an **Apps** section BELOW (lazy). Each
/// row is the real app/category icon + name (via `Label(token)`, which renders
/// the system-provided icon + label on the kid device — the name is not readable
/// as a `String`) plus a remove "x".
///
/// Tapping a row expands an inline **bind panel** below it (accordion). The app
/// panel embeds `AppStoreBindPanel` (App Store search); the category panel embeds
/// `CategoryTagPanel` (suggestion capsules). Picking a result/tag binds the token,
/// saves a LocalAliasStore alias immediately (so name-lock works even if the
/// upload fails), then uploads to the backend in a detached `Task` and re-saves
/// with the backend's real alias key. Unbound apps/categories are NEVER uploaded —
/// upload happens ONLY inside the bind handlers.
struct AppControlsV2View: View {
    let childDeviceID: UUID
    @EnvironmentObject var apiClient: APIClient

    @State private var selection: FamilyActivitySelection = DefaultLockGroupStore.load()
    @State private var showPicker = false

    // Accordion: at most one app and one category expanded at a time.
    @State private var expandedApp: ApplicationToken?
    @State private var expandedCategory: ActivityCategoryToken?

    // Soft inline error surfaced if a bind upload fails. The local alias is always
    // saved first, so a failure here never blocks naming on this device.
    @State private var bindError: String?

    // Bumped after a successful local bind so each row re-reads its `MatchedState`
    // from LocalAliasStore — a just-bound app flips to "Matched" without a reload.
    @State private var refreshTick = 0

    // Which matched app row the user tapped "Rebind" on. While set, that row shows
    // the App Store search panel instead of its review; cleared on collapse, on
    // opening a different row, and after a successful (re)bind.
    @State private var rebindingApp: ApplicationToken?

    var body: some View {
        // Fix 1 — the SCREEN is the container, not a small floating card.
        //
        // A full-screen, full-width `ScrollView` + top-aligned `VStack` fills the
        // device on a plain neutral page background. There is NO bounded white
        // card / warm tray wrapping the whole screen (the prototype's lines 66-67
        // outer tray are its demo phone-bezel framing, not real device chrome).
        // Each ROW supplies its own card. Because the scrolling screen (not a
        // resizable card) is the container, expanding a row grows the row in place
        // and pushes the rows below down WITHIN the scroll — the overall frame
        // never resizes or jumps.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                subtitle
                if let bindError {
                    bindErrorBanner(bindError)
                }
                categoriesSection
                appsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.evPageBg)
        .sheet(isPresented: $showPicker) {
            CombinedPickerSheet(
                initialSelection: selection,
                onSave: { newSelection in
                    DefaultLockGroupStore.save(newSelection)
                    reload()
                    showPicker = false
                },
                onCancel: { showPicker = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            // Prototype: <h2 font-size:19px; font-weight:500> — not a heavy title.
            Text("App Controls")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.evTextPrimary)

            Spacer()

            // Prototype `.evac-add`: transparent pill, hairline-strong border,
            // bright-green label (#16A34A), 13px medium, 7×12 padding, radius 10.
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                    Text("Add")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.evAccentGreen)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.evHairlineStrong, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 3)
    }

    private var subtitle: some View {
        // Prototype: 12px, text-secondary (#5f5e5a), line-height 1.5.
        Text("These all lock together as a group. Add an alias to a single one to also lock it by name.")
            .font(.system(size: 12))
            .foregroundStyle(Color.evTextSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 14)
    }

    private func bindErrorBanner(_ message: String) -> some View {
        // Prototype warning tones: bg #FAEEDA on text #854F0B, radius 10.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0x854F0B))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0x854F0B))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(hex: 0xFAEEDA), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 12)
    }

    // MARK: - Categories (top, all shown)

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Categories")

            if selection.categoryTokens.isEmpty {
                emptyText("No categories.")
            } else {
                ForEach(Array(selection.categoryTokens), id: \.self) { token in
                    CategoryRow(
                        token: token,
                        state: matchedState(forCategory: token, tick: refreshTick),
                        isExpanded: expandedCategory == token,
                        onToggle: { toggleCategory(token) },
                        onRemove: {
                            if expandedCategory == token {
                                withAnimation(Self.accordionAnimation) { expandedCategory = nil }
                            }
                            DefaultLockGroupStore.removeCategory(token)
                            reload()
                        },
                        onPick: { suggestion in bindCategory(token, suggestion: suggestion) }
                    )
                }
            }
        }
    }

    // MARK: - Apps (below, lazy)

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Apps")
                .padding(.top, 18)

            if selection.applicationTokens.isEmpty {
                emptyText("No apps.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(selection.applicationTokens), id: \.self) { token in
                        AppRow(
                            token: token,
                            apiClient: apiClient,
                            state: matchedState(forApp: token, tick: refreshTick),
                            isExpanded: expandedApp == token,
                            isRebinding: rebindingApp == token,
                            onToggle: { toggleApp(token) },
                            onRemove: {
                                if expandedApp == token {
                                    withAnimation(Self.accordionAnimation) { expandedApp = nil }
                                }
                                rebindingApp = nil
                                DefaultLockGroupStore.removeApp(token)
                                reload()
                            },
                            onRebind: { rebindingApp = token },
                            onPick: { result in bindApp(token, result: result) },
                            onManual: { name in
                                bindApp(token, result: CatalogSearchResult(canonicalName: name, bundleID: nil, aliases: []))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Accordion toggles (only one expanded at a time)

    /// Shared curve for the accordion's in-place unfold (Goal A). A high-damping
    /// spring reads as a calm, graceful drawer that settles without any bounce or
    /// overshoot — "平缓展开、收起". The height eased by this drives the reveal.
    private static let accordionAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.9)

    private func toggleApp(_ token: ApplicationToken) {
        bindError = nil
        // Collapsing this row, or opening a different one, always drops any
        // in-progress rebind so a re-opened matched row shows its review again.
        rebindingApp = nil
        withAnimation(Self.accordionAnimation) {
            if expandedApp == token {
                expandedApp = nil
            } else {
                expandedApp = token
                expandedCategory = nil
            }
        }
    }

    private func toggleCategory(_ token: ActivityCategoryToken) {
        bindError = nil
        rebindingApp = nil
        withAnimation(Self.accordionAnimation) {
            if expandedCategory == token {
                expandedCategory = nil
            } else {
                expandedCategory = token
                expandedApp = nil
            }
        }
    }

    // MARK: - App bind handler (onPick + onManual share this)

    private func bindApp(_ appToken: ApplicationToken, result: CatalogSearchResult) {
        guard let b64 = (try? JSONEncoder().encode(appToken))?.base64EncodedString() else { return }
        var row = PendingAppRow(tokenBase64: b64)
        row.bind(result)
        row.confirm()
        guard let upload = row.makeUploadApp(sourceDeviceID: childDeviceID) else { return }

        // 1) Local alias FIRST so name-lock works even if the upload never lands.
        LocalAliasStore.shared.saveApplicationAliases(
            token: appToken,
            displayName: upload.displayName,
            bundleIdentifier: upload.bundleID
        )

        // Collapse the accordion immediately — the bind is committed locally.
        withAnimation(Self.accordionAnimation) { expandedApp = nil }
        rebindingApp = nil
        bindError = nil
        // Re-read MatchedState so the just-bound app flips to "Matched".
        refreshTick &+= 1

        // 2) upload, then 3) re-save with the backend's real alias_key. Detached
        // so a slow/failed sync never blocks the UI; failure is a soft inline note.
        Task {
            do {
                let resp = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: [upload])
                let key = resp.apps.first {
                    $0.displayName == upload.displayName
                        && $0.bundleID == upload.bundleID
                        && $0.tokenKind.lowercased() != "category"
                }?.id
                LocalAliasStore.shared.saveApplicationAliases(
                    token: appToken,
                    displayName: upload.displayName,
                    bundleIdentifier: upload.bundleID,
                    catalogAliasKey: key
                )
            } catch {
                // Local alias already saved — do NOT block. Surface a soft note.
                await MainActor.run {
                    bindError = "Saved on this device. Couldn't sync to Evlin yet — it'll lock by name here, but won't be lockable from parent chat until the sync succeeds."
                }
            }
        }
    }

    // MARK: - Category bind handler

    private func bindCategory(_ catToken: ActivityCategoryToken, suggestion: AppleScreenTimeCategorySuggestion) {
        guard let b64 = (try? JSONEncoder().encode(catToken))?.base64EncodedString() else { return }
        let row = PendingCategoryRow(
            semanticKey: suggestion.semanticKey,
            displayName: suggestion.displayName,
            tokenBase64: b64
        )
        let upload = row.makeUploadCategory(sourceDeviceID: childDeviceID)

        // 1) Local alias FIRST — display name + every alias variant (mirrors
        // AddAppFlowView's category save) so name-lock works even if upload fails.
        LocalAliasStore.shared.saveCategoryToken(catToken, forName: upload.displayName)
        for alias in upload.aliases {
            LocalAliasStore.shared.saveCategoryToken(catToken, forName: alias)
        }

        // Collapse the accordion immediately — the bind is committed locally.
        withAnimation(Self.accordionAnimation) { expandedCategory = nil }
        bindError = nil
        // Re-read MatchedState so the just-bound category flips to "Matched".
        refreshTick &+= 1

        // 2) upload, then 3) re-save every name with the backend's real alias_key.
        Task {
            do {
                let resp = try await apiClient.mergeChildAppCatalog(deviceID: childDeviceID, apps: [upload])
                let key = resp.apps.first {
                    $0.displayName == upload.displayName
                        && $0.tokenKind.lowercased() == "category"
                }?.id
                LocalAliasStore.shared.saveCategoryToken(catToken, forName: upload.displayName, catalogAliasKey: key)
                for alias in upload.aliases {
                    LocalAliasStore.shared.saveCategoryToken(catToken, forName: alias, catalogAliasKey: key)
                }
            } catch {
                await MainActor.run {
                    bindError = "Saved on this device. Couldn't sync to Evlin yet — it'll lock by name here, but won't be lockable from parent chat until the sync succeeds."
                }
            }
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String) -> some View {
        // Prototype `.evac-sub`: 11px, weight 500, text-tertiary, uppercase,
        // letter-spacing .04em (~0.44pt at 11px), 6px bottom margin.
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .kerning(0.44)
            .foregroundStyle(Color.evTextTertiary)
            .padding(.bottom, 6)
    }

    private func emptyText(_ text: String) -> some View {
        // Prototype empty state: 12px, text-tertiary.
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.evTextTertiary)
            .padding(.vertical, 4)
    }

    private func reload() {
        selection = DefaultLockGroupStore.load()
    }

    // MARK: - Local "is this still matched?" state (pure reads of LocalAliasStore)

    /// App Controls v2 runs on the kid device, which holds the tokens locally. The
    /// "matched?" signal is derived ONLY from local token presence — never a backend
    /// row field (the lazy-tag conversion discards `token_available`/`status`).
    ///
    /// `tick` is unused in the body; it threads `refreshTick` through the row's
    /// initializer so SwiftUI re-invokes this after a bind and the chip updates.
    private func matchedState(forApp appToken: ApplicationToken, tick: Int) -> MatchedState {
        let keys = LocalAliasStore.shared.applicationLookupKeys(equalTo: appToken)
        let hasAliasKey = LocalAliasStore.shared.catalogAppTargets()
            .contains { !Set($0.lookupKeys).isDisjoint(with: keys) }
        let localTokenPresent = keys.contains { LocalAliasStore.shared.applicationToken(forLookupKey: $0) == appToken }
        return MatchedState.from(hasAliasKey: hasAliasKey, localTokenPresent: localTokenPresent)
    }

    private func matchedState(forCategory catToken: ActivityCategoryToken, tick: Int) -> MatchedState {
        let keys = LocalAliasStore.shared.categoryLookupKeys(equalTo: catToken)
        let hasAliasKey = LocalAliasStore.shared.catalogCategoryTargets()
            .contains { LocalAliasStore.shared.categoryToken(forName: $0.name) == catToken }
        let localTokenPresent = keys.contains { LocalAliasStore.shared.categoryToken(forName: $0) == catToken }
        return MatchedState.from(hasAliasKey: hasAliasKey, localTokenPresent: localTokenPresent)
    }
}

// MARK: - Rows

/// A category row: collapsed = icon + name (`Label(token)`) + chevron + remove "x".
/// Expanded = the same header (highlighted) with an inline `CategoryTagPanel` below.
private struct CategoryRow: View {
    let token: ActivityCategoryToken
    let state: MatchedState
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onPick: (AppleScreenTimeCategorySuggestion) -> Void

    var body: some View {
        EvacAccordionRow(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onRemove: onRemove,
            label: {
                HStack(spacing: 8) {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.evOnSurface)
                    MatchedChip(state: state, isExpanded: isExpanded)
                }
            },
            panel: {
                CategoryTagPanel(
                    name: "this category",
                    selectedKey: nil,
                    onPick: onPick
                )
            }
        )
    }
}

/// An app row: collapsed = icon + name (`Label(token)`) + chevron + remove "x".
/// Expanded = the same header (highlighted) with an inline panel below.
///
/// Fix 2 — the expanded panel is state-aware:
/// - `.matched` / `.matchedNeedsRefresh`, and NOT currently rebinding → a REVIEW
///   panel ("iOS shows / You picked / Rebind"), so re-opening an already-matched
///   app no longer dumps the user back into a search.
/// - `.unmatched`, OR the user tapped "Rebind" on this row → the `AppStoreBindPanel`
///   search, exactly as before.
private struct AppRow: View {
    let token: ApplicationToken
    let apiClient: APIClient
    let state: MatchedState
    let isExpanded: Bool
    let isRebinding: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onRebind: () -> Void
    let onPick: (CatalogSearchResult) -> Void
    let onManual: (String) -> Void

    private var showsReview: Bool {
        switch state {
        case .matched, .matchedNeedsRefresh:
            return !isRebinding
        case .unmatched:
            return false
        }
    }

    var body: some View {
        EvacAccordionRow(
            isExpanded: isExpanded,
            onToggle: onToggle,
            onRemove: onRemove,
            label: {
                HStack(spacing: 8) {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.evOnSurface)
                    MatchedChip(state: state, isExpanded: isExpanded)
                }
            },
            panel: {
                if showsReview {
                    MatchedReviewPanel(token: token, onRebind: onRebind)
                } else {
                    AppStoreBindPanel(
                        appName: "this app",
                        apiClient: apiClient,
                        onPick: onPick,
                        onManual: onManual
                    )
                }
            }
        )
    }
}

/// The "already matched" review panel, replicating `CatalogBindRowView.confirmationBody`'s
/// "iOS shows / You picked" layout inline (so we never edit that file). Shows the real
/// on-device `Label(token)` next to the bound name + artwork the parent picked, plus a
/// "Rebind" escape that swaps this row back to the App Store search panel.
private struct MatchedReviewPanel: View {
    let token: ApplicationToken
    let onRebind: () -> Void

    /// The bound name/bundle for "You picked", read from the same LocalAliasStore
    /// catalog target that `matchedState(forApp:)` uses to decide "matched": the
    /// app target whose lookup keys intersect this token's lookup keys.
    private var boundResult: CatalogSearchResult? {
        let keys = Set(LocalAliasStore.shared.applicationLookupKeys(equalTo: token))
        guard let target = LocalAliasStore.shared.catalogAppTargets()
            .first(where: { !Set($0.lookupKeys).isDisjoint(with: keys) })
        else { return nil }
        // artworkURL defaults nil → CatalogArtworkView shows its letter-tile fallback.
        return CatalogSearchResult(canonicalName: target.label, bundleID: target.bundleID, aliases: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Same "why two near-identical rows?" caption as confirmationBody.
            Text("Double-check it's the same app:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                reviewRow(label: "iOS shows") {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Divider().padding(.leading, 12)
                reviewRow(label: "You picked") {
                    HStack(spacing: 8) {
                        if let result = boundResult {
                            EvacArtworkView(result: result, size: 24)
                            Text(result.canonicalName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text("Saved on this device")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                Spacer(minLength: 0)
                Button("Rebind", action: onRebind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.evAccentGreen)
            }
        }
    }

    /// Full-width "iOS shows" / "You picked" row (fixed-width caption + content),
    /// replicating `CatalogBindRowView.matchRow` so long names never wrap/truncate.
    @ViewBuilder
    private func reviewRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Inline replica of `CatalogBindRowView`'s private `CatalogArtworkView` (we can't
/// reference that file-private type), used by the "You picked" review row. With a
/// nil `artworkURL` it renders the first-letter gradient tile fallback.
private struct EvacArtworkView: View {
    let result: CatalogSearchResult
    let size: CGFloat

    var body: some View {
        Group {
            if let url = result.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size <= 30 ? 8 : 10, style: .continuous))
    }

    private var fallbackIcon: some View {
        RoundedRectangle(cornerRadius: size <= 30 ? 8 : 10, style: .continuous)
            .fill(iconFill)
            .overlay {
                Text(String(result.canonicalName.prefix(1)).uppercased())
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
            }
    }

    private var iconFill: LinearGradient {
        LinearGradient(
            colors: result.bundleID == nil ? [.gray.opacity(0.7), .gray] : [.orange, .pink, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Shared accordion row chrome: a tappable bordered card holding the token label +
/// a trailing chevron + a remove "x". When expanded, the border turns green and the
/// supplied bind `panel` is rendered inline below the header, mirroring the
/// prototype's `.evac-row.open` + `.evac-panel`.
private struct EvacAccordionRow<Label: View, Panel: View>: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let label: Label
    @ViewBuilder let panel: Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: tapping the label area toggles the accordion; the remove "x"
            // and chevron are siblings so the "x" never triggers a toggle.
            HStack(spacing: 11) {
                Button(action: onToggle) {
                    HStack(spacing: 11) {
                        label
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Prototype: chevron flips down→up and goes green when open.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isExpanded ? Color.evAccentGreen : Color.evTextTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.evTextTertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }

            // GOAL A — graceful in-place "unfold".
            //
            // The panel + its top divider live inside a height-clipping container.
            // When `isExpanded` flips, `withAnimation` at the call site eases the
            // container's intrinsic height from 0 → content height, so the panel is
            // *revealed in place* (drawer opening downward) and the rows below glide
            // down — no `.move(edge:)` translate, so nothing flies in from above.
            // `.transition(.opacity)` cross-fades the content as the height grows.
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    Divider()
                        .overlay(Color.evHairline)
                        .padding(.top, 11)
                    panel
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .clipped()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isExpanded ? Color.evAccentGreenSoft : Color.evCardFill)
        )
        // Prototype lines 154-155: when open, the header + panel are ONE connected
        // card — green border, radius 12, `overflow:hidden`. The open header drops
        // its own border and takes a faint green tint with no gap before the panel.
        // Clipping to the rounded rect keeps the green tint + panel inside the radius.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isExpanded ? Color.evAccentGreen : Color.evHairline,
                        lineWidth: isExpanded ? 1 : 0.5)
        )
        .padding(.bottom, 8)
    }
}

/// The local "Matched" status pill, mirroring the prototype's `.evac-chip`.
///
/// - `.matched` → green "Matched" chip (`#15803D` on `#DCFCE7`), with a check.
/// - `.matchedNeedsRefresh` → weaker gray "Matched · Needs refresh" chip.
/// - `.unmatched` → nothing (the row stays tappable to bind).
///
/// Like the prototype, the chip is hidden while the row is expanded (binding) so
/// it doesn't compete with the inline panel.
private struct MatchedChip: View {
    let state: MatchedState
    let isExpanded: Bool

    var body: some View {
        if !isExpanded {
            switch state {
            case .matched:
                chip(
                    icon: "checkmark",
                    text: "Matched",
                    foreground: Color(red: 0.082, green: 0.502, blue: 0.239), // #15803D
                    background: Color(red: 0.863, green: 0.988, blue: 0.906)  // #DCFCE7
                )
            case .matchedNeedsRefresh:
                chip(
                    icon: "arrow.triangle.2.circlepath",
                    text: "Matched · Needs refresh",
                    foreground: Color.evTextTertiary,
                    background: Color(hex: 0xE9E7E0) // prototype tertiary bg
                )
            case .unmatched:
                EmptyView()
            }
        }
    }

    private func chip(icon: String, text: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
        .fixedSize()
    }
}

#if DEBUG
#Preview {
    AppControlsV2View(childDeviceID: UUID())
        .environmentObject(APIClient(baseURL: "http://preview.local"))
}
#endif
