// Evlin iOS/Evlin iOS/Views/Debug/TokenPickerView.swift
//
// Lazy-tagging primitive: parent picks which `Label(token)` corresponds to
// a given chat-supplied name (e.g. "Instagram"), and we persist the binding
// in `LocalAliasStore`. Chat resolution thereafter goes from
// `target_request: "Instagram"` → token → shield, transparently.
//
// This view does NOT know about chat. Caller passes a hint + kind, and an
// `onSelect` callback. It's reusable wherever a hosted-token name needs to
// be bound (chat lazy-tag, batch onboarding wizard, etc).
import SwiftUI
import FamilyControls
import ManagedSettings

struct TokenPickerView: View {
    enum Kind {
        case app
        case category
    }

    /// The name chat (or whoever) is trying to resolve. Shown prominently
    /// so the parent knows which slot they're filling.
    let hint: String
    let kind: Kind

    /// Returns the chosen token (or nil if the parent dismissed without picking).
    /// The view also writes the alias to LocalAliasStore before calling back.
    let onSelect: (Any?) -> Void

    @EnvironmentObject var screenTimeManager: ScreenTimeManager
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""

    /// When the parent doesn't see the app in the current Managed Apps
    /// selection, they need to open Apple's picker to add it first — neither
    /// our alias store nor `store.shield.applications` can target a token
    /// that was never picked. This sheet hosts the system FamilyActivityPicker
    /// for that path. `includeEntireCategory: true` matches production init
    /// (see `ScreenTimeManager.selectedApps` and `HomeSettingsSheet`).
    @State private var systemPickerOpen = false

    private var apps: [ApplicationToken] {
        Array(screenTimeManager.selectedApps.applicationTokens)
            .sorted { $0.hashValue < $1.hashValue }
    }
    private var categories: [ActivityCategoryToken] {
        Array(screenTimeManager.selectedApps.categoryTokens)
            .sorted { $0.hashValue < $1.hashValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                listBody
                Divider()
                expandSelectionFooter
            }
            .navigationTitle(kind == .app ? "Tag app" : "Tag category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onSelect(nil)
                        dismiss()
                    }
                }
            }
            // Apple's system picker — for when the target app was never added
            // to Managed Apps and so isn't in our list above. Selection writes
            // directly back into `screenTimeManager.selectedApps` so the next
            // pass through `listBody` sees the newly added tokens.
            .familyActivityPicker(
                isPresented: $systemPickerOpen,
                selection: $screenTimeManager.selectedApps
            )
            .onChange(of: systemPickerOpen) { _, isOpen in
                if !isOpen { screenTimeManager.saveSelection() }
            }
        }
    }

    private var expandSelectionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Don't see \u{201C}\(hint)\u{201D} above?")
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("It's not in Managed Apps yet. Open Apple's picker to add it, then come back and tag it.")
                .font(.custom("Inter", size: 11))
                .foregroundStyle(Color.evOutline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                systemPickerOpen = true
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which one is")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("\u{201C}\(hint)\u{201D}?")
                .font(.custom("Manrope", size: 24).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text("Tap the \(kind == .app ? "app" : "category") below. Evlin will remember it for next time.")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOutline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
    }

    @ViewBuilder
    private var listBody: some View {
        switch kind {
        case .app:
            if apps.isEmpty {
                emptyState(message: "No managed apps yet — open Settings → Managed Apps and pick some.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(apps.enumerated()), id: \.offset) { _, tok in
                            appRow(token: tok)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        case .category:
            if categories.isEmpty {
                emptyState(message: "No managed categories yet — open Settings → Managed Apps and tap a category row to include the whole group.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { _, tok in
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
        Button {
            // Persist the alias under both lowercase and original-case hints
            // — `LocalAliasStore.applicationToken(forLookupKey:)` is case-insensitive
            // but stores under lowercased keys.
            LocalAliasStore.shared.saveApplicationAliases(
                token: token,
                displayName: hint,
                bundleIdentifier: nil
            )
            onSelect(token)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(token: ActivityCategoryToken) -> some View {
        Button {
            LocalAliasStore.shared.saveCategoryToken(token, forName: hint)
            onSelect(token)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Inter", size: 15).weight(.semibold))
                    .foregroundStyle(Color.evOnSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.evSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.evOutline.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    TokenPickerView(hint: "Instagram", kind: .app) { _ in }
        .environmentObject(ScreenTimeManager.shared)
}
#endif
