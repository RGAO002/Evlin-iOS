import SwiftUI

struct ChildFirstSavedListStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let childDeviceID: UUID
    let onContinue: () -> Void

    @StateObject private var model = LockListManagerModel()
    @State private var showAddApp = false
    @State private var showAddList = false
    @State private var lastSaved: String?

    private var hasConfiguredTargets: Bool {
        !model.apps.isEmpty || !model.lists.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                VStack(spacing: Spacing.lg) {
                    Text("Choose what Evlin can lock")
                        .font(.evHeadlineLarge)
                        .foregroundStyle(Color.evPrimary)
                        .multilineTextAlignment(.center)
                    Text("Add individual apps for natural-language locks like “lock Instagram”, or save a list for groups of apps.")
                        .font(.evBodyMedium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .padding(.horizontal, Spacing.xl)
                }
                .padding(.top, Spacing.section)

                VStack(spacing: Spacing.md) {
                    Button {
                        showAddApp = true
                    } label: {
                        OnboardingLockTargetActionRow(
                            icon: "plus.app",
                            title: "Add app",
                            subtitle: "Pick one app, confirm the system label, and name it."
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showAddList = true
                    } label: {
                        OnboardingLockTargetActionRow(
                            icon: "rectangle.stack.badge.plus",
                            title: "Add list",
                            subtitle: "Pick multiple apps or categories and save them as one lock target."
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.xl)

                configuredSummary

                Button(action: onContinue) {
                    Text(hasConfiguredTargets ? "Continue" : "Skip for now")
                        .font(.evLabelLarge)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(hasConfiguredTargets ? Color.evOnPrimary : Color.evOnSurfaceVariant)
                .padding(.vertical, Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(hasConfiguredTargets ? Color.evPrimary : Color.evSurfaceContainer)
                )
                .padding(.horizontal, Spacing.xl)

                Text("You can edit this later from Kid mode → Apps. Later edits require the Evlin PIN.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
        .onAppear { model.reload() }
        .sheet(isPresented: $showAddApp) {
            NavigationStack {
                AddAppFlowView(childDeviceID: childDeviceID) { _ in
                    showAddApp = false
                    lastSaved = "App saved"
                    model.reload()
                }
                .environmentObject(apiClient)
            }
        }
        .sheet(isPresented: $showAddList) {
            NavigationStack {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: childDeviceID,
                    mode: "child_device"
                ) { name in
                    showAddList = false
                    lastSaved = "'\(name)' saved"
                    model.reload()
                }
                .environmentObject(apiClient)
            }
        }
    }

    @ViewBuilder
    private var configuredSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Saved targets")
                    .font(.evHeadlineSmall)
                    .foregroundStyle(Color.evPrimary)
                Spacer()
                Text("\(model.apps.count) apps · \(model.lists.count) lists")
                    .font(.evLabelMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }

            if let lastSaved {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                    Text(lastSaved)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evSecondary)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(Color.evSecondaryContainer)
                )
            } else if !hasConfiguredTargets {
                Text("Nothing saved yet. Add at least one app or list if you want parent commands to work immediately after setup.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .fill(Color.evSurfaceContainer)
                    )
            }

            if !model.apps.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(model.apps.prefix(3)) { app in
                        NameWithIcon(name: app.label, kind: .app, titleFont: .evLabelLarge)
                    }
                    if model.apps.count > 3 {
                        Text("+ \(model.apps.count - 3) more apps")
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }

            if !model.lists.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(model.lists.prefix(3), id: \.self) { list in
                        NameWithIcon(name: list, kind: .savedList, titleFont: .evLabelLarge)
                    }
                    if model.lists.count > 3 {
                        Text("+ \(model.lists.count - 3) more lists")
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evSurfaceContainer)
        )
        .padding(.horizontal, Spacing.xl)
    }
}

private struct OnboardingLockTargetActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.evOnPrimary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(Color.evPrimary)
                )

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(title)
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evOnSurface)
                Text(subtitle)
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evOutline)
        }
        .padding(Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evSurfaceContainer)
        )
    }
}
