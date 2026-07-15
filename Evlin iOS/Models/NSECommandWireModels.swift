import Foundation

// MARK: - Wire decode (verbatim mirror of APIClient.PollCommandDTO/PollTargetDTO)

/// APIClient is intentionally not linked into the push-applier target, so the
/// child-command wire shape and its mapping to LockCommand live here.
nonisolated struct NSEWireCommand: Decodable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: NSEWireTarget
    let duration_minutes: Int?
    let issued_at: String
    let lock_source: String?
    let unlock_sources: [String]?

    static func lockCommand(from poll: NSEWireCommand) -> LockCommand {
        let tier = poll.tier.flatMap(ShieldTier.init(rawValue:))
        let trimmedHint = poll.target.category_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryHint = (trimmedHint?.isEmpty == false) ? trimmedHint : nil
        let target = CommandTarget(
            bundleID: poll.target.bundle_id,
            listName: poll.target.list_name,
            listID: poll.target.list_id.flatMap(UUID.init(uuidString:)),
            categoryHint: categoryHint,
            targetAll: poll.target.target_all ?? false,
            allSelected: poll.target.all_selected,
            defaultLockGroup: poll.target.default_lock_group,
            originalRequest: poll.target.original_request,
            targetDisplay: poll.target.target_display,
            targetChildID: poll.target.target_child_id.flatMap(UUID.init(uuidString:)),
            hasPendingBlob: poll.target.has_pending_blob ?? false,
            forceDowngrade: poll.target.force_downgrade ?? false,
            catalogTokenDataBase64: poll.target.catalog_token_data_base64,
            catalogCategoryTokenDataBase64: poll.target.catalog_category_token_data_base64,
            catalogApplicationTokenDataBase64s: poll.target.applications ?? [],
            catalogCategoryTokenDataBase64s: poll.target.applicationCategories ?? [],
            lockSource: NSECommandSourceResolver.lockSource(
                topLevel: poll.lock_source,
                target: poll.target.lock_source
            ),
            unlockSources: NSECommandSourceResolver.unlockSources(
                topLevel: poll.unlock_sources,
                target: poll.target.unlock_sources
            ),
            earnedOverrideUsageDate: poll.target.earned_override_usage_date
        )
        let action = CommandAction(rawValue: poll.action) ?? .shield
        let issued = ISO8601DateFormatter().date(from: poll.issued_at) ?? Date()
        return LockCommand(
            id: poll.command_id,
            action: action,
            tier: tier,
            target: target,
            durationMinutes: poll.duration_minutes,
            issuedAt: issued
        )
    }
}

nonisolated struct NSEWireTarget: Decodable {
    let bundle_id: String?
    let list_name: String?
    let list_id: String?
    let has_pending_blob: Bool?
    let category_hint: String?
    let target_all: Bool?
    let all_selected: Bool?
    let default_lock_group: Bool?
    let original_request: String
    let target_display: String?
    let target_child_id: String?
    let force_downgrade: Bool?
    let catalog_token_data_base64: String?
    let catalog_category_token_data_base64: String?
    let applications: [String]?
    let applicationCategories: [String]?
    let lock_source: String?
    let unlock_sources: [String]?
    let earned_override_usage_date: String?

    private enum CodingKeys: String, CodingKey {
        case bundle_id
        case list_name
        case list_id
        case has_pending_blob
        case category_hint
        case categoryHint
        case target_all
        case all_selected
        case default_lock_group
        case original_request
        case target_display
        case target_child_id
        case force_downgrade
        case applications
        case applicationCategories
        case application_categories
        case lock_source
        case unlock_sources
        case earned_override_usage_date
        case canonicalCatalogTokenDataBase64 = "catalog_token_data_base64"
        case canonicalCatalogCategoryTokenDataBase64 = "catalog_category_token_data_base64"
        case legacyTokenDataBase64 = "token_data_base64"
        case legacyCategoryTokenDataBase64 = "category_token_data_base64"
        case camelCatalogTokenDataBase64 = "catalogTokenDataBase64"
        case camelCatalogCategoryTokenDataBase64 = "catalogCategoryTokenDataBase64"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundle_id = try c.decodeIfPresent(String.self, forKey: .bundle_id)
        list_name = try c.decodeIfPresent(String.self, forKey: .list_name)
        list_id = try c.decodeIfPresent(String.self, forKey: .list_id)
        has_pending_blob = try c.decodeIfPresent(Bool.self, forKey: .has_pending_blob)
        category_hint = try c.decodeIfPresent(String.self, forKey: .category_hint)
            ?? c.decodeIfPresent(String.self, forKey: .categoryHint)
        target_all = try c.decodeIfPresent(Bool.self, forKey: .target_all)
        all_selected = try c.decodeIfPresent(Bool.self, forKey: .all_selected)
        default_lock_group = try c.decodeIfPresent(Bool.self, forKey: .default_lock_group)
        original_request = try c.decodeIfPresent(String.self, forKey: .original_request) ?? ""
        target_display = try c.decodeIfPresent(String.self, forKey: .target_display)
        target_child_id = try c.decodeIfPresent(String.self, forKey: .target_child_id)
        force_downgrade = try c.decodeIfPresent(Bool.self, forKey: .force_downgrade)
        catalog_token_data_base64 = try c.decodeIfPresent(String.self, forKey: .canonicalCatalogTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .legacyTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .camelCatalogTokenDataBase64)
        catalog_category_token_data_base64 = try c.decodeIfPresent(String.self, forKey: .canonicalCatalogCategoryTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .legacyCategoryTokenDataBase64)
            ?? c.decodeIfPresent(String.self, forKey: .camelCatalogCategoryTokenDataBase64)
        applications = try c.decodeIfPresent([String].self, forKey: .applications)
        applicationCategories = try c.decodeIfPresent([String].self, forKey: .applicationCategories)
            ?? c.decodeIfPresent([String].self, forKey: .application_categories)
        lock_source = try c.decodeIfPresent(String.self, forKey: .lock_source)
        unlock_sources = try c.decodeIfPresent([String].self, forKey: .unlock_sources)
        earned_override_usage_date =
            try c.decodeIfPresent(String.self, forKey: .earned_override_usage_date)
    }
}

nonisolated enum NSECommandWireDecoder {
    static func decode(_ data: Data) throws -> LockCommand {
        let dto = try JSONDecoder().decode(NSEWireCommand.self, from: data)
        return NSEWireCommand.lockCommand(from: dto)
    }
}
