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
        "\(unresolvedName) isn’t in your kid’s list yet. To lock it, add it on their phone, or try `block \(unresolvedName)`."
    }
}
