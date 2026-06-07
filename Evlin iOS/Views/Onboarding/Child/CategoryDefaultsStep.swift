import SwiftUI
import FamilyControls
import ManagedSettings
import Sentry

/// Maps semantic Chat categories ("games", "social", "entertainment") to the
/// opaque ActivityCategoryTokens produced by FamilyActivityPicker.
struct CategoryDefaultsStep: View {
    @EnvironmentObject private var apiClient: APIClient

    let childDeviceID: UUID
    let onContinue: () -> Void

    @State private var selections: [String: FamilyActivitySelection] = [:]
    // `includeEntireCategory: true` so a category-row tap captures the whole
    // category as one ActivityCategoryToken instead of expanding to N app tokens.
    // Without this flag iOS treats the row as "select all apps inside" — which
    // (a) gives no category token at all and (b) misses apps installed later.
    @State private var pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
    @State private var activeCategory: SemanticCategory?
    @State private var showPicker = false
    @State private var isSaving = false

    private let categories: [SemanticCategory] = [
        .init(key: "games", title: "Games", example: "Roblox, Minecraft, Fortnite", required: true),
        .init(key: "social", title: "Social", example: "Instagram, TikTok, Snapchat", required: true),
        .init(key: "entertainment", title: "Entertainment", example: "YouTube, Netflix, Twitch", required: true),
        .init(key: "education", title: "Education", example: "Learning and study apps", required: false),
        .init(key: "productivity", title: "Productivity", example: "Tools, finance, work apps", required: false),
    ]

    private var configuredKeys: Set<String> {
        Set(selections.compactMap { key, selection in
            selection.categoryTokens.isEmpty ? nil : key
        })
    }

    private var requiredKeys: Set<String> {
        Set(categories.filter(\.required).map(\.key))
    }

    private var canContinue: Bool {
        requiredKeys.isSubset(of: configuredKeys)
    }

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Category Shield Setup")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Pick one Screen Time category for each label below. This lets Chat say \"lock Instagram\" and use the Social shield instead of hiding the app icon.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            VStack(spacing: Spacing.md) {
                ForEach(categories) { category in
                    categoryRow(category)
                }
            }
            .familyActivityPicker(isPresented: $showPicker, selection: $pickerSelection)
            .onChange(of: showPicker) { _, isPresented in
                if !isPresented {
                    commitPickerSelection()
                }
            }

            if !canContinue {
                Text("Set up Games, Social, and Entertainment to make default shield mode reliable.")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button {
                Task {
                    await saveCategoriesAndContinue()
                }
            } label: {
                Text(isSaving ? "Saving..." : "Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(canContinue ? Color.evPrimary : Color.evOutline)
            )
            .disabled(!canContinue || isSaving)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private func categoryRow(_ category: SemanticCategory) -> some View {
        let configured = configuredKeys.contains(category.key)

        return Button {
            activeCategory = category
            pickerSelection = selections[category.key]
                ?? FamilyActivitySelection(includeEntireCategory: true)
            showPicker = true
        } label: {
            HStack(spacing: Spacing.lg) {
                Image(systemName: configured ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(configured ? Color.evPrimary : Color.evOutline)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Text(category.title)
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evPrimary)
                        if category.required {
                            Text("REQUIRED")
                                .font(.evLabelMedium)
                                .evLabelStyle()
                                .foregroundStyle(Color.evOnPrimary)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.evPrimary))
                        }
                    }

                    Text(category.example)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }

                Spacer()

                Text(configured ? "Change" : "Pick")
                    .font(.evLabelMedium)
                    .foregroundStyle(Color.evPrimary)
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .stroke(configured ? Color.evPrimary : Color.evOutlineVariant, lineWidth: configured ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func commitPickerSelection() {
        guard let category = activeCategory else { return }
        defer {
            activeCategory = nil
            pickerSelection = FamilyActivitySelection(includeEntireCategory: true)
        }

        guard !pickerSelection.categoryTokens.isEmpty else { return }
        selections[category.key] = pickerSelection
    }

    @MainActor
    private func saveCategoriesAndContinue() async {
        guard !isSaving else { return }
        isSaving = true
        defer {
            isSaving = false
            onContinue()
        }

        let captured = captureCategoryRows()
        guard !captured.uploads.isEmpty else { return }

        do {
            let response = try await apiClient.uploadChildAppCatalog(
                deviceID: childDeviceID,
                apps: captured.uploads.map(\.upload)
            )
            let responseIDs = Set(response.apps.map(\.id))
            for item in captured.uploads {
                let catalogAliasKey = responseIDs.contains(item.row.id)
                    ? item.row.id
                    : response.apps.first(where: { $0.displayName == item.row.displayName && $0.tokenKind == "category" })?.id
                LocalAliasStore.shared.saveCategoryToken(
                    item.token,
                    forName: item.semanticKey,
                    catalogAliasKey: catalogAliasKey ?? item.row.id
                )
                LocalAliasStore.shared.saveCategoryToken(
                    item.token,
                    forName: item.row.displayName,
                    catalogAliasKey: catalogAliasKey ?? item.row.id
                )
            }
        } catch {
            #if DEBUG
            print("[CategoryDefaultsStep] category catalog upload failed: \(error)")
            #endif
            SentrySDK.capture(error: error)
        }
    }

    private func captureCategoryRows() -> (uploads: [CapturedCategoryUpload], localOnlyCount: Int) {
        var uploads: [CapturedCategoryUpload] = []
        var localOnlyCount = 0

        for category in categories {
            guard let token = selections[category.key]?.categoryTokens.first else { continue }
            LocalAliasStore.shared.saveCategoryToken(token, forName: category.key)
            LocalAliasStore.shared.saveCategoryToken(token, forName: category.title)

            do {
                let tokenBase64 = try AppCatalogBlobEncoder.base64(token)
                let row = PendingCategoryRow(
                    semanticKey: category.key,
                    displayName: category.title,
                    tokenBase64: tokenBase64
                )
                uploads.append(
                    CapturedCategoryUpload(
                        semanticKey: category.key,
                        token: token,
                        row: row,
                        upload: row.makeUploadCategory(sourceDeviceID: childDeviceID)
                    )
                )
            } catch {
                localOnlyCount += 1
                #if DEBUG
                print("[CategoryDefaultsStep] category token encode failed for \(category.key): \(error)")
                #endif
            }
        }

        return (uploads, localOnlyCount)
    }
}

private struct SemanticCategory: Identifiable, Equatable {
    let key: String
    let title: String
    let example: String
    let required: Bool

    var id: String { key }
}

private struct CapturedCategoryUpload {
    let semanticKey: String
    let token: ActivityCategoryToken
    let row: PendingCategoryRow
    let upload: ChildAppCatalogUploadApp
}
