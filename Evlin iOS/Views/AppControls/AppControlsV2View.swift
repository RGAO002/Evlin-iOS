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
    /// Embedded mode (onboarding). When true, the screen drops its own title
    /// header + subtitle + page background + outer ScrollView + DEBUG reset so the
    /// hosting `OnboardingV2ScreenContainer` owns title/explainer/background, and
    /// surfaces a prominent empty-state CTA. The standalone path (false) is
    /// byte-for-byte unchanged.
    var embedded: Bool = false
    /// Called after EVERY mutation of the lock group (picker save / remove / bind)
    /// so an embedding onboarding step can recompute "has ≥1 selected".
    var onSelectionChanged: (() -> Void)? = nil

    init(childDeviceID: UUID, embedded: Bool = false, onSelectionChanged: (() -> Void)? = nil) {
        self.childDeviceID = childDeviceID
        self.embedded = embedded
        self.onSelectionChanged = onSelectionChanged
    }

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
        Group {
            if embedded {
                // Embedded (onboarding): no page-background, no DEBUG reset, and NO
                // big title/subtitle (the container supplies those). The container
                // does NOT scroll its content slot, so we keep a ScrollView here so a
                // long app list scrolls inside the step.
                ScrollView {
                    contentStack
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
            } else {
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
                        contentStack
                        #if DEBUG
                        debugResetControl
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color.evPageBg)
            }
        }
        // Fix 1 — dismissing the whole screen while a Rebind is pending (the user
        // tapped "Rebind" but never picked a new match) leaves the app unbound.
        .onDisappear { cancelRebindIfPending() }
        .sheet(isPresented: $showPicker) {
            CombinedPickerSheet(
                initialSelection: selection,
                onSave: { newSelection in
                    DefaultLockGroupStore.save(mergePreservingPriorSelection(newSelection))
                    reload()
                    onSelectionChanged?()
                    showPicker = false
                },
                onCancel: { showPicker = false }
            )
        }
    }

    /// The shared body content (error banner + categories + apps). In embedded
    /// mode an empty group ALSO shows a prominent full-width "Pick apps &
    /// categories" CTA so an empty onboarding screen has an obvious action.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bindError {
                bindErrorBanner(bindError)
            }
            if embedded {
                embeddedAddControl
            }
            categoriesSection
            appsSection
        }
    }

    // MARK: - Embedded add control (onboarding)

    /// In embedded mode the onboarding container hides the v2's own "App Controls"
    /// header (and its inline "Add"), so the parent still needs a way to open the
    /// picker. When the group is EMPTY we show a prominent full-width "Pick apps &
    /// categories" CTA; once anything is picked we show a compact top-right "Add".
    @ViewBuilder
    private var embeddedAddControl: some View {
        let isEmpty = selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty
        if isEmpty {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Pick apps & categories")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.evAccentGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.evAccentGreen, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        } else {
            HStack {
                Spacer()
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
            .padding(.bottom, 8)
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

    // MARK: - DEBUG reset (Fix B — never ships)

    #if DEBUG
    /// DEBUG-only "Reset App Controls data" — wipes ALL local aliases/categories +
    /// the "Locked set" group + the catalog alias-key index, then SNAPSHOT-wipes the
    /// backend catalog (`apps: []` deletes every catalog row for this kid device), so
    /// the tester can start clean and re-run the bind/rebind/unbind flow. Wrapped in
    /// `#if DEBUG` so it never reaches a release build.
    private var debugResetControl: some View {
        Button(role: .destructive) {
            // Wipes local aliases + categories + the "Locked set" group + catalog index.
            LocalAliasStore.shared.removeAllAliases()
            // Snapshot-wipe the backend catalog (apps: [] deletes every row). Best-effort.
            Task { try? await apiClient.uploadChildAppCatalog(deviceID: childDeviceID, apps: []) }
            reload()                 // selection now empty
            refreshTick &+= 1
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                Text("Reset App Controls data (debug)")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.evTextDanger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.evTextDanger.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 24)
    }
    #endif

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
                        selectedKey: selectedCategoryKey(forCategory: token, tick: refreshTick),
                        onToggle: { toggleCategory(token) },
                        onRemove: {
                            if expandedCategory == token {
                                withAnimation(Self.accordionAnimation) { expandedCategory = nil }
                            }
                            DefaultLockGroupStore.removeCategory(token)
                            reload()
                            onSelectionChanged?()
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
                                // Fix 1 — removing the app while a Rebind is pending
                                // still drops the (now-stale) alias before the row goes.
                                // (If a rebind was pending on THIS token, this also
                                // deletes the backend row — Fix A.2 — so the named-app
                                // cleanup below no-ops, having no alias left to find.)
                                cancelRebindIfPending()
                                // Fix A.3 — for a NAMED app, also clean up its local alias
                                // and DELETE its backend catalog row so it stops showing in
                                // the parent "Manage aliases" after removal. Unnamed apps
                                // have no alias keys → this whole block no-ops.
                                let aliasKey = backendAliasKey(forApp: token)
                                let aliasLookupKeys = LocalAliasStore.shared.applicationLookupKeys(equalTo: token)
                                if !aliasLookupKeys.isEmpty {
                                    LocalAliasStore.shared.removeApplicationAliases(keys: aliasLookupKeys)
                                    if let aliasKey {
                                        Task { try? await apiClient.deleteChildAppControlTarget(deviceID: childDeviceID, aliasKey: aliasKey) }
                                    }
                                }
                                DefaultLockGroupStore.removeApp(token)
                                reload()
                                onSelectionChanged?()
                            },
                            onRebind: {
                                // Tapping Rebind clears the OLD binding RIGHT AWAY
                                // (delete backend row + dict entry + local alias), then
                                // shows the search — no need to exit/Done to clean up.
                                unbindApp(token)
                                rebindingApp = token
                            },
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
        // Fix 1 — if the user tapped "Rebind" and is now LEAVING that row without
        // having picked a new match, the deferred-unbind fires (alias removed →
        // row reverts to .unmatched). Must run BEFORE mutating `expandedApp`.
        cancelRebindIfPending()
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
        // Opening a category collapses any expanded app — if that app had a pending
        // Rebind, leaving it unbinds it (Fix 1).
        cancelRebindIfPending()
        withAnimation(Self.accordionAnimation) {
            if expandedCategory == token {
                expandedCategory = nil
            } else {
                expandedCategory = token
                expandedApp = nil
            }
        }
    }

    // MARK: - Deferred-unbind (Fix 1)

    /// Fix 1 — Rebind defaults to UNBIND when no new match is provided.
    ///
    /// Tapping "Rebind" keeps `rebindingApp` set (alias still present, search shown).
    /// If the user then LEAVES that row without picking a new match — collapses it,
    /// opens another row/category, removes the app, or dismisses the whole screen —
    /// this drops the old binding: it removes the app's alias keys, so
    /// `matchedState(forApp:)` recomputes to `.unmatched` and the row reverts to the
    /// search affordance. The app STAYS in `DefaultLockGroupStore` (still a group
    /// member) — only its name alias is gone, so it's an unnamed member again.
    ///
    /// A SUCCESSFUL new bind must NOT route through here: `bindApp(...)` clears
    /// `rebindingApp` directly AFTER saving the new alias, so no unbind ever fires.
    private func cancelRebindIfPending() {
        guard let token = rebindingApp else { return }
        rebindingApp = nil
        // Safety net: Rebind already unbinds immediately (see onRebind), so this is a
        // no-op on the normal path. Kept for any leave path that didn't go through Rebind.
        unbindApp(token)
    }

    /// Immediately drop a binding: remove the local name alias (so MatchedState
    /// recomputes to `.unmatched`) AND delete the backend catalog row + its orphaned
    /// family-dictionary entry. Used when "Rebind" is tapped (clear the OLD binding
    /// right away, not on exit) and as the leave-without-pick safety net. No-op if
    /// the token has no alias (already unbound).
    private func unbindApp(_ token: ApplicationToken) {
        let keys = LocalAliasStore.shared.applicationLookupKeys(equalTo: token)
        guard !keys.isEmpty else { return }
        // Capture the backend alias key BEFORE wiping the local alias (which makes
        // backendAliasKey(forApp:) unresolvable).
        let aliasKey = backendAliasKey(forApp: token)
        LocalAliasStore.shared.removeApplicationAliases(keys: keys)
        refreshTick &+= 1
        // DELETE the backend catalog row (+ orphaned dictionary entry, server-side).
        // Best-effort, detached; never blocks the UI.
        if let aliasKey {
            Task { try? await apiClient.deleteChildAppControlTarget(deviceID: childDeviceID, aliasKey: aliasKey) }
        }
    }

    // MARK: - App bind handler (onPick + onManual share this)

    private func bindApp(_ appToken: ApplicationToken, result: CatalogSearchResult) {
        guard let b64 = (try? JSONEncoder().encode(appToken))?.base64EncodedString() else { return }
        var row = PendingAppRow(tokenBase64: b64)
        row.bind(result)
        row.confirm()
        guard let upload = row.makeUploadApp(sourceDeviceID: childDeviceID) else { return }

        // Fix A.1 — REBIND deletes the OLD backend row. Capture this token's CURRENT
        // backend alias key BEFORE the local-alias replace below wipes it. After the
        // new row uploads, we delete this stale row (guarded so re-confirming the SAME
        // app — which upserts to the same key — is never deleted). Without this,
        // `mergeChildAppCatalog` (additive) leaves A's row behind on rebind A→B, and it
        // shows forever in the parent "Manage aliases".
        let oldAliasKey = backendAliasKey(forApp: appToken)

        // 0) Rebind = REPLACE, not append. `saveApplicationAliases` is additive, so
        // without this a re-bind leaves the previous name's keys on this token. Since
        // `catalogAppTargets().label` picks the alphabetically-first key, the review
        // would keep showing the earlier-bound app no matter what the user re-picks.
        // Clear this token's prior alias keys first; no-op on a fresh bind.
        let priorKeys = LocalAliasStore.shared.applicationLookupKeys(equalTo: appToken)
        if !priorKeys.isEmpty {
            LocalAliasStore.shared.removeApplicationAliases(keys: priorKeys)
        }

        // 1) Local alias FIRST so name-lock works even if the upload never lands.
        LocalAliasStore.shared.saveApplicationAliases(
            token: appToken,
            displayName: upload.displayName,
            bundleIdentifier: upload.bundleID
        )

        // Collapse the accordion immediately — the bind is committed locally.
        withAnimation(Self.accordionAnimation) { expandedApp = nil }
        // Fix 1 — SUCCESS path: the new alias is already saved (step 1 above), so we
        // clear `rebindingApp` DIRECTLY here. We must NOT call cancelRebindIfPending()
        // — that would remove the alias we just saved. Ordering is load-bearing:
        // new alias saved → rebindingApp = nil → no unbind fires → rebound, kept.
        rebindingApp = nil
        bindError = nil
        // Re-read MatchedState so the just-bound app flips to "Matched".
        refreshTick &+= 1
        // A bind is a group mutation (the app is now a NAMED member). Let an
        // embedding onboarding step recompute "has ≥1 selected".
        onSelectionChanged?()

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
                // Fix A.1 — now that the NEW row exists, delete the stale OLD backend
                // row. Guard `oldAliasKey != key` so re-confirming the SAME app (which
                // upserts to the same row/key) is never deleted. Best-effort.
                if let oldAliasKey, oldAliasKey != key {
                    try? await apiClient.deleteChildAppControlTarget(deviceID: childDeviceID, aliasKey: oldAliasKey)
                }
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

        // 0) Re-tag = REPLACE, not append. `saveCategoryToken` is additive, so
        // without this a re-tag leaves the PREVIOUS tag's name keys on this token.
        // Then `selectedCategoryKey` (and name-lock resolution) keep matching the
        // old tag — the chip highlight never moves, so the tag looks unchangeable.
        // Clear this token's prior category keys first; no-op on a first tag.
        for key in LocalAliasStore.shared.categoryLookupKeys(equalTo: catToken) {
            LocalAliasStore.shared.removeCategory(named: key)
        }

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
        // A bind is a group mutation (the category is now a NAMED member). Let an
        // embedding onboarding step recompute "has ≥1 selected".
        onSelectionChanged?()

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

    // MARK: - Backend alias-key lookup (Fix A)

    /// A token's CURRENT backend alias key — the `aliasKey` of the catalog target whose
    /// lookup keys intersect this token's lookup keys, or nil if the app is unnamed
    /// (never bound). Used to DELETE the stale backend catalog row on rebind / unbind /
    /// remove so the parent "Manage aliases" list never accumulates orphaned rows.
    private func backendAliasKey(forApp token: ApplicationToken) -> UUID? {
        let keys = LocalAliasStore.shared.applicationLookupKeys(equalTo: token)
        return LocalAliasStore.shared.catalogAppTargets()
            .first { !Set($0.lookupKeys).isDisjoint(with: keys) }?.aliasKey
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

    /// Task 4 — the `semanticKey` of the suggestion this category is currently tagged
    /// with, or nil if untagged. Category aliases are stored lowercased in
    /// LocalAliasStore, so a matched category's lookup keys hold either the suggestion's
    /// semanticKey ("social") or its displayName ("Social") lowercased. We match a
    /// suggestion when either matches, and hand back its (canonical) `semanticKey` so
    /// CategoryTagPanel highlights the chip whose `semanticKey == selectedKey`.
    ///
    /// `tick` is unused in the body; it threads `refreshTick` so SwiftUI recomputes
    /// after a bind (the just-tagged chip lights up without a reload).
    private func selectedCategoryKey(forCategory catToken: ActivityCategoryToken, tick: Int) -> String? {
        let keys = Set(LocalAliasStore.shared.categoryLookupKeys(equalTo: catToken).map { $0.lowercased() })
        return AppleScreenTimeCategorySuggestions.all.first { sugg in
            keys.contains(sugg.semanticKey.lowercased()) || keys.contains(sugg.displayName.lowercased())
        }?.semanticKey
    }
}

// Apple's picker folds an individually-selected app into a category when that
// category is picked, dropping it from applicationTokens. We apply union semantics
// on Save: any app or category that was in the stored group BEFORE the picker was
// opened is re-inserted unless the user explicitly removed it via the row "x" buttons
// (which call DefaultLockGroupStore.removeApp/removeCategory directly and are already
// absent from the store when Save fires). This lets a single app (e.g. Instagram) and
// a whole category (e.g. Social) coexist in the group independently.
func mergePreservingPriorSelection(_ picked: FamilyActivitySelection) -> FamilyActivitySelection {
    mergePreservingPriorSelection(picked, prior: DefaultLockGroupStore.load())
}

/// Pure inner implementation — accepts the prior selection explicitly so it is
/// unit-testable without touching DefaultLockGroupStore.
func mergePreservingPriorSelection(
    _ picked: FamilyActivitySelection,
    prior: FamilyActivitySelection
) -> FamilyActivitySelection {
    var merged = picked
    // Re-add any app that was in the prior group but the picker dropped (e.g. because
    // a containing category was selected). Named and unnamed apps alike are preserved.
    for token in prior.applicationTokens where !merged.applicationTokens.contains(token) {
        merged.applicationTokens.insert(token)
    }
    // Re-add any category that was in the prior group but the picker dropped.
    for token in prior.categoryTokens where !merged.categoryTokens.contains(token) {
        merged.categoryTokens.insert(token)
    }
    return merged
}

// MARK: - Rows

/// A category row: collapsed = icon + name (`Label(token)`) + chevron + remove "x".
/// Expanded = the same header (highlighted) with an inline `CategoryTagPanel` below.
private struct CategoryRow: View {
    let token: ActivityCategoryToken
    let state: MatchedState
    let isExpanded: Bool
    /// Task 4 — the `semanticKey` of the currently-applied suggestion (or nil), so a
    /// matched category opens with its current tag chip highlighted in CategoryTagPanel.
    let selectedKey: String?
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
                    selectedKey: selectedKey,
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
                    MatchedReviewPanel(token: token, apiClient: apiClient, onRebind: onRebind)
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

/// The "already matched" review panel. Reuses the shared `MatchedAppReviewView`
/// (the SAME component the old Add App flow renders) so both screens are identical:
/// the real on-device `Label(token)` next to the bound name + artwork the parent
/// picked, plus a "Rebind" escape that swaps this row back to the App Store search.
private struct MatchedReviewPanel: View {
    let token: ApplicationToken
    let apiClient: APIClient
    let onRebind: () -> Void

    /// Task 3 — the App Store result fetched live for "You picked", carrying the real
    /// `artworkURL` AND the proper-case `canonicalName`. The local catalog target only
    /// persists a LOWERCASE name (LocalAliasStore keys are lowercased) + bundleID, so
    /// the reconstructed result is lowercase with no artwork → capitalized letter-tile
    /// fallback. Once this lands (network), the real icon + proper-case name show.
    /// Stays nil for manual binds (bundleID == nil), before the fetch completes, and on
    /// any failure — capitalized fallback persists, silently.
    @State private var fetchedArtwork: CatalogSearchResult?

    /// The bound name/bundle for "You picked", read from the same LocalAliasStore
    /// catalog target that `matchedState(forApp:)` uses to decide "matched": the
    /// app target whose lookup keys intersect this token's lookup keys. The `label`
    /// is LOWERCASE (alias keys are lowercased).
    private var boundResult: CatalogSearchResult? {
        let keys = Set(LocalAliasStore.shared.applicationLookupKeys(equalTo: token))
        guard let target = LocalAliasStore.shared.catalogAppTargets()
            .first(where: { !Set($0.lookupKeys).isDisjoint(with: keys) })
        else { return nil }
        // artworkURL defaults nil → CatalogArtworkView shows its letter-tile fallback.
        return CatalogSearchResult(canonicalName: target.label, bundleID: target.bundleID, aliases: [])
    }

    /// Task 3 — the result handed to `MatchedAppReviewView` as "You picked":
    /// - Live-fetched (proper-case `canonicalName` + real `artworkURL`) once it lands.
    /// - Else the locally-reconstructed result with `.capitalized` name ("instagram"
    ///   → "Instagram"); manual binds (bundleID == nil) keep that + the letter tile.
    private var resolvedPicked: CatalogSearchResult? {
        if let fetchedArtwork { return fetchedArtwork }
        guard let bound = boundResult else { return nil }
        return CatalogSearchResult(
            canonicalName: bound.canonicalName.capitalized,
            bundleID: bound.bundleID,
            aliases: []
        )
    }

    var body: some View {
        Group {
            if let picked = resolvedPicked {
                MatchedAppReviewView(token: token, picked: picked, onRebind: { onRebind() })
            } else {
                // No local catalog target resolved (shouldn't happen for a matched
                // row); keep a quiet placeholder rather than an empty panel.
                Text("Saved on this device")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // Task 3 — fetch the real App Store icon + proper-case name for "You picked".
        // Non-blocking; the capitalized letter-tile shows until (and unless) this
        // lands. Failure is silent.
        .task { await fetchArtworkIfPossible() }
    }

    /// Task 3 — re-runs the SAME catalog search the bind panel uses to recover the
    /// `artworkURL` + proper-case name the local store never persisted. Only attempts
    /// when the bound entry carries a bundleID (manual binds have none → keep the
    /// capitalized letter tile). Matches by bundleID, falling back to a
    /// case-insensitive name match; both failure modes leave `fetchedArtwork` nil so
    /// the reconstructed tile stays.
    private func fetchArtworkIfPossible() async {
        guard let bound = boundResult,
              let boundBundleID = bound.bundleID,
              !boundBundleID.isEmpty
        else { return }
        // Same call AppStoreBindPanel makes: catalogSearch(q:) → [DTO] → .map(\.result).
        guard let dtos = try? await apiClient.catalogSearch(q: bound.canonicalName) else { return }
        let results = dtos.map(\.result)
        let match = results.first { $0.bundleID == boundBundleID }
            ?? results.first { $0.canonicalName.caseInsensitiveCompare(bound.canonicalName) == .orderedSame }
        if let match { fetchedArtwork = match }
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
