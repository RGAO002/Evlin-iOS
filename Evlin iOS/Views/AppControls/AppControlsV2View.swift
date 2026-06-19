import SwiftUI
import FamilyControls
import ManagedSettings

/// App Controls v2 screen — Task 3.1 SHELL (collapsed rows only).
///
/// Replicates the `app-controls-v2-prototype.html` "App Controls v2" layout:
/// header "App Controls" + an "Add" button, a subtitle, then a **Categories**
/// section ON TOP (all rows shown) and an **Apps** section BELOW (lazy). Each
/// row is the real app/category icon + name (via `Label(token)`, which renders
/// the system-provided icon + label on the kid device — the name is not readable
/// as a `String`) plus a remove "x".
///
/// The accordion expand + inline bind panel and the "Matched" chip are LATER
/// tasks (3.2). This shell renders collapsed rows only and never shows the chip.
struct AppControlsV2View: View {
    @State private var selection: FamilyActivitySelection = DefaultLockGroupStore.load()
    @State private var showPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                subtitle
                categoriesSection
                appsSection
            }
            .padding(16)
        }
        .background(Color.evSurfaceContainer)
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
            Text("App Controls")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.evOnSurface)

            Spacer()

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Color.evSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.evOutline, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 3)
    }

    private var subtitle: some View {
        Text("These all lock together as a group. Add an alias to a single one to also lock it by name.")
            .font(.footnote)
            .foregroundStyle(Color.evOnSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 14)
    }

    // MARK: - Categories (top, all shown)

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Categories")

            if selection.categoryTokens.isEmpty {
                emptyText("No categories.")
            } else {
                ForEach(Array(selection.categoryTokens), id: \.self) { token in
                    CategoryRow(token: token) {
                        DefaultLockGroupStore.removeCategory(token)
                        reload()
                    }
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
                        AppRow(token: token) {
                            DefaultLockGroupStore.removeApp(token)
                            reload()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.medium))
            .kerning(0.5)
            .foregroundStyle(Color.evOutline)
            .padding(.bottom, 6)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.evOutline)
            .padding(.vertical, 4)
    }

    private func reload() {
        selection = DefaultLockGroupStore.load()
    }
}

// MARK: - Rows

/// A single collapsed category row: icon + name (`Label(token)`) + remove "x".
private struct CategoryRow: View {
    let token: ActivityCategoryToken
    let onRemove: () -> Void

    var body: some View {
        EvacRow(onRemove: onRemove) {
            Label(token)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.evOnSurface)
        }
    }
}

/// A single collapsed app row: icon + name (`Label(token)`) + remove "x".
private struct AppRow: View {
    let token: ApplicationToken
    let onRemove: () -> Void

    var body: some View {
        EvacRow(onRemove: onRemove) {
            Label(token)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.evOnSurface)
        }
    }
}

/// Shared row chrome: a bordered card holding the token label + a trailing
/// remove "x". Mirrors the prototype's `.evac-row`.
private struct EvacRow<Content: View>: View {
    let onRemove: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 11) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 0.5)
        )
        .padding(.bottom, 8)
    }
}

#if DEBUG
#Preview {
    AppControlsV2View()
}
#endif
