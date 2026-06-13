import Foundation

enum LazyTagCatalogTargetType: String, Codable, Sendable, CaseIterable {
    case app
    case category
    case list

    var title: String {
        switch self {
        case .app: return "App"
        case .category: return "Category"
        case .list: return "List"
        }
    }
}

struct LazyTagCatalogTarget: Identifiable, Codable, Sendable, Equatable, Hashable {
    let aliasKey: UUID
    let type: LazyTagCatalogTargetType
    let displayName: String
    let aliases: [String]
    let bundleID: String?
    let artworkURL: URL?
    let isManual: Bool
    let memberCount: Int?

    var id: UUID { aliasKey }

    init(
        aliasKey: UUID,
        type: LazyTagCatalogTargetType,
        displayName: String,
        aliases: [String] = [],
        bundleID: String? = nil,
        artworkURL: URL? = nil,
        isManual: Bool = false,
        memberCount: Int? = nil
    ) {
        self.aliasKey = aliasKey
        self.type = type
        self.displayName = displayName
        self.aliases = aliases
        self.bundleID = bundleID
        self.artworkURL = artworkURL
        self.isManual = isManual
        self.memberCount = memberCount
    }

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case type = "target_type"
        case displayName = "display_name"
        case aliases
        case bundleID = "bundle_id"
        case artworkURL = "artwork_url"
        case isManual = "is_manual"
        case memberCount = "member_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliasKey = try container.decode(UUID.self, forKey: .aliasKey)
        type = try container.decode(LazyTagCatalogTargetType.self, forKey: .type)
        displayName = try container.decode(String.self, forKey: .displayName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount)
    }

    var supportingText: String {
        switch type {
        case .app:
            if let bundleID, !bundleID.isEmpty { return bundleID }
            return isManual ? "Manual app binding" : "Catalog app"
        case .category:
            return "Current + future apps Apple classifies as \(displayName)"
        case .list:
            if let memberCount {
                return "\(memberCount) catalog target\(memberCount == 1 ? "" : "s")"
            }
            return "Custom catalog list"
        }
    }

    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        if displayName.lowercased().contains(needle) { return true }
        if bundleID?.lowercased().contains(needle) == true { return true }
        return aliases.contains { $0.lowercased().contains(needle) }
    }
}

struct LazyTagCatalogSection: Sendable, Equatable {
    let type: LazyTagCatalogTargetType
    let title: String
    let targets: [LazyTagCatalogTarget]
}

struct LazyTagCatalogPresentation: Sendable, Equatable {
    let sections: [LazyTagCatalogSection]
    let informMessage: String?

    var isInformOnly: Bool {
        informMessage != nil
    }
}

enum LazyTagCatalogModel {
    static func sections(
        from targets: [LazyTagCatalogTarget],
        searchText: String
    ) -> [LazyTagCatalogSection] {
        let filtered = targets.filter { $0.matches(searchText: searchText) }
        return LazyTagCatalogTargetType.allCases.map { type in
            LazyTagCatalogSection(
                type: type,
                title: type.title,
                targets: filtered
                    .filter { $0.type == type }
                    .sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
            )
        }
    }

    static func presentation(
        targets: [LazyTagCatalogTarget],
        searchText: String,
        unresolvedName: String
    ) -> LazyTagCatalogPresentation {
        let sections = sections(from: targets, searchText: searchText)
        let hasCandidates = sections.contains { !$0.targets.isEmpty }
        return LazyTagCatalogPresentation(
            sections: sections,
            informMessage: hasCandidates ? nil : informMessage(for: unresolvedName)
        )
    }

    private static func informMessage(for unresolvedName: String) -> String {
        // Verbatim Task 11 empty-state copy (uses the actual unresolved phrase
        // for X). Backticks wrap only the app phrase in the `block X` hint.
        "\(unresolvedName) isn’t in your kid’s list yet. Add it on their phone, or try block `\(unresolvedName)`."
    }
}

// MARK: - Lock-setup save rules (Task 10, Step 3)

/// Pure, UI-free save-rule logic for the kid-side "Lock setup" surface. These
/// are split out of the view so they can be unit-tested in isolation
/// (`LazyTagCatalogModelTests`). The four sections (Installed apps, Broad
/// categories, Lists, Advanced shield tokens) each gate Save through one of
/// these checks.
enum LockSetupSaveRules {

    /// Why a candidate list name is rejected. `.valid` means it may be saved.
    enum ListNameValidation: Equatable {
        case valid
        case empty
        /// Equals one of the canonical category keys (`games`, `social`, …).
        /// A list named after a category would collide with category targets
        /// when the parent locks "by name".
        case reservedCategoryWord
        /// Case-insensitively duplicates an existing list on this device.
        case duplicate
    }

    /// Canonical category keys the backend / chat / `SemanticCategoryAliasSync`
    /// emit. A saved list MUST NOT be named after one of these, or a parent's
    /// "lock <name>" could ambiguously resolve to either the list or the broad
    /// category. Kept in sync with `SemanticCategoryAliasSync.inferredSemanticKey`.
    static let reservedCategoryWords: Set<String> = [
        "games",
        "social",
        "entertainment",
        "education",
        "productivity",
    ]

    /// True when `name` (trimmed, lowercased) is a reserved category word.
    static func isReservedCategoryWord(_ name: String) -> Bool {
        reservedCategoryWords.contains(normalized(name))
    }

    /// Validate a candidate list name against emptiness, reserved category
    /// words, and case-insensitive duplicates among `existingNames`.
    static func validateListName(
        _ name: String,
        existingNames: [String]
    ) -> ListNameValidation {
        let clean = normalized(name)
        guard !clean.isEmpty else { return .empty }
        if reservedCategoryWords.contains(clean) { return .reservedCategoryWord }
        if existingNames.contains(where: { normalized($0) == clean }) { return .duplicate }
        return .valid
    }

    /// Convenience boolean wrapper around `validateListName`.
    static func isValidListName(_ name: String, existingNames: [String]) -> Bool {
        validateListName(name, existingNames: existingNames) == .valid
    }

    // MARK: App rows

    /// An app row is "labeled" once it has a non-blank display name. Unlabeled
    /// token rows must block Save until labeled or removed.
    static func appRowIsLabeled(displayName: String) -> Bool {
        !normalized(displayName).isEmpty
    }

    /// True if ANY app-token row is still unlabeled — Save is blocked while so.
    static func hasUnlabeledAppRows(displayNames: [String]) -> Bool {
        displayNames.contains { !appRowIsLabeled(displayName: $0) }
    }

    /// An app target is saveable only when it is labeled AND either confirmed
    /// against the Family Dictionary (verified binding) OR given an explicit
    /// manual bundle id. A bare token with no binding is not lockable by name.
    static func appTargetIsSaveable(
        displayName: String,
        isFamilyDictionaryConfirmed: Bool,
        manualBundleID: String?
    ) -> Bool {
        guard appRowIsLabeled(displayName: displayName) else { return false }
        let hasManualBundle = !normalized(manualBundleID ?? "").isEmpty
        return isFamilyDictionaryConfirmed || hasManualBundle
    }

    // MARK: Category rows

    /// A category target is saveable only when its category token was captured.
    static func categoryTargetIsSaveable(hasCategoryToken: Bool) -> Bool {
        hasCategoryToken
    }

    // MARK: Lists

    /// A list is saveable when its name validates and it has at least one
    /// member (app and/or category members are both allowed).
    static func listIsSaveable(
        name: String,
        existingNames: [String],
        appMemberCount: Int,
        categoryMemberCount: Int
    ) -> Bool {
        guard isValidListName(name, existingNames: existingNames) else { return false }
        return (appMemberCount + categoryMemberCount) > 0
    }

    // MARK: Helpers

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum AddTargetMode: String, Sendable, Equatable {
    case app
    case category

    var title: String {
        switch self {
        case .app: return "Add app"
        case .category: return "Add category"
        }
    }
}

enum AddTargetFlowRules {
    enum Action: Equatable {
        case saveApps
        case saveCategories
        case reject
    }

    struct Decision: Equatable {
        let action: Action
        let warning: String?
    }

    static func decision(
        mode: AddTargetMode,
        appCount: Int,
        categoryCount: Int,
        webDomainCount: Int
    ) -> Decision {
        if webDomainCount > 0 {
            return .init(action: .reject, warning: "Websites are not supported here.")
        }

        switch mode {
        case .app:
            if appCount > 0 {
                return .init(
                    action: .saveApps,
                    warning: categoryCount > 0 ? "Category selections were ignored. Add categories from Add category." : nil
                )
            }
            if categoryCount > 0 {
                return .init(action: .reject, warning: "Expand the category or search to select individual apps.")
            }
            return .init(action: .reject, warning: "Pick at least one app first.")
        case .category:
            if categoryCount > 0 {
                return .init(
                    action: .saveCategories,
                    warning: appCount > 0 ? "App selections were ignored. Add apps from Add app." : nil
                )
            }
            if appCount > 0 {
                return .init(action: .reject, warning: "Select a category, not an individual app.")
            }
            return .init(action: .reject, warning: "Pick at least one category first.")
        }
    }
}

struct LockSetupCatalogRow: Equatable, Identifiable {
    let id: UUID
    let type: LazyTagCatalogTargetType
    let title: String
    let subtitle: String?
    let badgeText: String?
    let bundleID: String?
    let artworkURL: URL?
    let memberCount: Int?
}

struct LockSetupCatalogPresentationModel: Equatable {
    let appRows: [LockSetupCatalogRow]
    let categoryRows: [LockSetupCatalogRow]
    let listRows: [LockSetupCatalogRow]

    init(apps: [LockSetupTarget], categories: [LockSetupTarget], lists: [LockSetupTarget]) {
        appRows = apps.map { target in
            LockSetupCatalogRow(
                id: target.aliasKey,
                type: .app,
                title: target.displayName,
                subtitle: target.bundleID,
                badgeText: nil,
                bundleID: target.bundleID,
                artworkURL: target.artworkURL,
                memberCount: nil
            )
        }
        categoryRows = categories.map { target in
            LockSetupCatalogRow(
                id: target.aliasKey,
                type: .category,
                title: target.displayName,
                subtitle: nil,
                badgeText: nil,
                bundleID: nil,
                artworkURL: target.artworkURL,
                memberCount: nil
            )
        }
        listRows = lists.map { target in
            let count = target.memberCount ?? 0
            return LockSetupCatalogRow(
                id: target.aliasKey,
                type: .list,
                title: target.displayName,
                subtitle: "\(count) member\(count == 1 ? "" : "s")",
                badgeText: nil,
                bundleID: nil,
                artworkURL: target.artworkURL,
                memberCount: count
            )
        }
    }

    init(catalog: LockSetupCatalog) {
        self.init(
            apps: catalog.appTargets,
            categories: catalog.categoryTargets,
            lists: catalog.listTargets
        )
    }

    var hasUsableTarget: Bool {
        !appRows.isEmpty || !categoryRows.isEmpty || !listRows.isEmpty
    }

    var hasBlockableApp: Bool {
        appRows.contains { row in
            row.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}
