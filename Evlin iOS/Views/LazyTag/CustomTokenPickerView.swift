// Evlin iOS/Views/LazyTag/CustomTokenPickerView.swift
//
// Single-select picker presented as a `.sheet(item:)` from ChatView when
// ChatViewModel sets `activeLazyTagRequest`. Reads existing tokens from
// `screenTimeManager.selectedApps` and provides an "Add via Apple picker"
// footer to widen selection. After Apple-picker fallback, computes the
// before/after diff: if exactly 1 token was newly added, auto-select it
// (most common case — parent picked just the target app); if multiple,
// surface them at the top of the list.
//
// Note: There's a debug-only `Views/Debug/TokenPickerView.swift` that
// implements a similar primitive — that one is for the Settings probe
// page and is being kept as-is. CustomTokenPickerView is the production
// component. We don't migrate the debug view.
//
// ForEach id note: `Array(sortedApps.enumerated()), id: \.offset` uses
// list position as identity. Sheet lifecycle is short (~seconds per use)
// and the only reorder is once when Apple-picker fallback adds tokens.
// Acceptable risk for v1 — if reuse glitches surface during QA, swap to
// a stable wrapper keyed on `tok.hashValue`.

import SwiftUI
import FamilyControls
import ManagedSettings

struct CustomTokenPickerView: View {
    let request: LazyTagRequest
    let onSelect: (Any, LazyTagRequest) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppToken: ApplicationToken? = nil
    @State private var selectedCategoryToken: ActivityCategoryToken? = nil
    @State private var applePickerOpen = false
    @State private var pickerSelection: FamilyActivitySelection = FamilyActivitySelection()

    /// Captured before opening Apple picker so we can compute diff on dismiss.
    @State private var preApplePickerAppTokens: Set<ApplicationToken> = []
    @State private var preApplePickerCategoryTokens: Set<ActivityCategoryToken> = []

    /// Tokens added in the most recent Apple-picker session (rendered at top
    /// of list). Cleared when user picks one from the diff or cancels.
    @State private var newlyAddedAppTokens: Set<ApplicationToken> = []
    @State private var newlyAddedCategoryTokens: Set<ActivityCategoryToken> = []

    private var sortedApps: [ApplicationToken] {
        let all = Array(screenTimeManager.selectedApps.applicationTokens)
        let new = all.filter { newlyAddedAppTokens.contains($0) }
        let rest = all.filter { !newlyAddedAppTokens.contains($0) }
            .sorted { $0.hashValue < $1.hashValue }
        return new.sorted { $0.hashValue < $1.hashValue } + rest
    }
    private var sortedCategories: [ActivityCategoryToken] {
        let all = Array(screenTimeManager.selectedApps.categoryTokens)
        let new = all.filter { newlyAddedCategoryTokens.contains($0) }
        let rest = all.filter { !newlyAddedCategoryTokens.contains($0) }
            .sorted { $0.hashValue < $1.hashValue }
        return new.sorted { $0.hashValue < $1.hashValue } + rest
    }
    private var canSave: Bool {
        switch request.kind {
        case .app: return selectedAppToken != nil
        case .category: return selectedCategoryToken != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                listBody
                Divider()
                footer
            }
            .navigationTitle(request.kind == .app ? "Tag app" : "Tag category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTapped() }
                        .disabled(!canSave)
                }
            }
            .familyActivityPicker(isPresented: $applePickerOpen, selection: $pickerSelection)
            .onChange(of: applePickerOpen) { _, isOpen in
                if !isOpen { mergePickerIntoSelectedApps() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which one is")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("\u{201C}\(request.target)\u{201D}?")
                .font(.custom("Manrope", size: 24).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text("Tap the \(request.kind == .app ? "app" : "category") below. Evlin will remember it for next time.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    @ViewBuilder
    private var listBody: some View {
        switch request.kind {
        case .app:
            if sortedApps.isEmpty {
                emptyState(
                    message: "No apps in Managed Apps yet. Tap \u{201C}Add via Apple picker\u{201D} below to add \(request.target)."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(sortedApps.enumerated()), id: \.offset) { _, tok in
                            appRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        case .category:
            if sortedCategories.isEmpty {
                emptyState(
                    message: "No categories yet. Tap \u{201C}Add via Apple picker\u{201D} and tap the \(request.target) row."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(sortedCategories.enumerated()), id: \.offset) { _, tok in
                            categoryRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Color.evOutline)
            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appRow(token: ApplicationToken) -> some View {
        let isSelected = selectedAppToken == token
        let isNew = newlyAddedAppTokens.contains(token)
        return Button {
            selectedAppToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                if isNew {
                    Text("Just added")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(token: ActivityCategoryToken) -> some View {
        let isSelected = selectedCategoryToken == token
        let isNew = newlyAddedCategoryTokens.contains(token)
        return Button {
            selectedCategoryToken = token
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.evPrimary : Color.evOutline)
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                if isNew {
                    Text("Just added")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.evPrimary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.evPrimary.opacity(0.08) : Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.evPrimary : Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Don't see \u{201C}\(request.target)\u{201D}?")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("Open Apple's picker to add it. New tokens will appear at the top of the list.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openApplePicker()
            } label: {
                Label("Open Apple picker", systemImage: "plus.circle")
                    .font(.custom("Inter", size: 13).weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    private func openApplePicker() {
        // Snapshot before so we can diff on dismiss.
        preApplePickerAppTokens = screenTimeManager.selectedApps.applicationTokens
        preApplePickerCategoryTokens = screenTimeManager.selectedApps.categoryTokens
        // For category mode, the Apple picker MUST be initialized with
        // includeEntireCategory: true — without this, tapping a category row
        // enumerates individual app tokens instead of producing a single
        // ActivityCategoryToken.
        switch request.kind {
        case .app:
            pickerSelection = FamilyActivitySelection()
        case .category:
            pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
        }
        applePickerOpen = true
    }

    /// Apple picker dismissed. Merge into selectedApps (preserves shieldable
    /// authorization scope), compute diff, surface "just added" tokens at
    /// list top, auto-select if exactly one was added.
    private func mergePickerIntoSelectedApps() {
        var merged = screenTimeManager.selectedApps
        merged.applicationTokens.formUnion(pickerSelection.applicationTokens)
        merged.categoryTokens.formUnion(pickerSelection.categoryTokens)
        merged.webDomainTokens.formUnion(pickerSelection.webDomainTokens)
        // NOTE: `selection.applications` and `.categories` are get-only on
        // FamilyActivitySelection — see ScreenTimeManager.swift:49 ("get-only
        // — cannot restore metadata after plist decode"). We can't merge
        // them. The Label(token) view on the merged tokens still renders
        // names if Apple supplies them at view-time; the .applications
        // metadata array isn't required for shield calls.
        screenTimeManager.selectedApps = merged
        screenTimeManager.saveSelection()

        // Compute diff for highlighting + auto-select.
        let nowApps = screenTimeManager.selectedApps.applicationTokens
        let nowCats = screenTimeManager.selectedApps.categoryTokens
        let addedApps = nowApps.subtracting(preApplePickerAppTokens)
        let addedCats = nowCats.subtracting(preApplePickerCategoryTokens)
        newlyAddedAppTokens = addedApps
        newlyAddedCategoryTokens = addedCats

        // Auto-select if exactly one new (the common case: parent picked
        // just the target app).
        switch request.kind {
        case .app where addedApps.count == 1:
            selectedAppToken = addedApps.first
        case .category where addedCats.count == 1:
            selectedCategoryToken = addedCats.first
        default:
            break
        }
    }

    private func saveTapped() {
        switch request.kind {
        case .app:
            guard let tok = selectedAppToken else { return }
            onSelect(tok, request)
            dismiss()
        case .category:
            guard let tok = selectedCategoryToken else { return }
            onSelect(tok, request)
            dismiss()
        }
    }
}
