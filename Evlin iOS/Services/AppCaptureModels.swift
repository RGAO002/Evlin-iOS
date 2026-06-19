import Foundation
import FamilyControls
import ManagedSettings

/// Which capture path the parent chose.
enum CaptureKind: String, Sendable {
    case app
    case list
}

/// Plain counts pulled off a FamilyActivitySelection so validation is unit-testable
/// without minting real tokens.
struct SelectionCounts: Equatable, Sendable {
    let applicationTokens: Int
    let categoryTokens: Int
    let webDomainTokens: Int

    init(applicationTokens: Int, categoryTokens: Int, webDomainTokens: Int) {
        self.applicationTokens = applicationTokens
        self.categoryTokens = categoryTokens
        self.webDomainTokens = webDomainTokens
    }

    init(_ selection: FamilyActivitySelection) {
        self.init(
            applicationTokens: selection.applicationTokens.count,
            categoryTokens: selection.categoryTokens.count,
            webDomainTokens: selection.webDomainTokens.count
        )
    }
}

/// Result of gating a capture. `reason` drives the inline Save-disabled warning.
struct CaptureValidation: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case needExactlyOneApp = "Pick exactly one app for Add App."
        case categoryOrWebNotAllowedForApp = "Add App can't include a category or website - use Add List for those."
        case listEmpty = "Pick at least one app or category."
    }

    let isValid: Bool
    let reason: Reason?

    static let valid = CaptureValidation(isValid: true, reason: nil)
    static func invalid(_ reason: Reason) -> CaptureValidation {
        CaptureValidation(isValid: false, reason: reason)
    }
}

/// Apple gives no single-select picker; "pick exactly one app" is post-hoc
/// introspection of the returned selection.
enum CapturePathValidator {
    static func validate(_ kind: CaptureKind, _ counts: SelectionCounts) -> CaptureValidation {
        switch kind {
        case .app:
            if counts.categoryTokens > 0 || counts.webDomainTokens > 0 {
                return .invalid(.categoryOrWebNotAllowedForApp)
            }
            if counts.applicationTokens != 1 {
                return .invalid(.needExactlyOneApp)
            }
            return .valid
        case .list:
            if counts.applicationTokens == 0 && counts.categoryTokens == 0 {
                return .invalid(.listEmpty)
            }
            return .valid
        }
    }
}

enum AddTargetPickerConfiguration {
    /// Use category expansion even in Add App. iOS can collapse a single-app
    /// category/search result into a category token; expansion gives us the
    /// contained ApplicationToken when the system is willing to expose it.
    static func includeEntireCategory(for mode: AddTargetMode) -> Bool {
        switch mode {
        case .app, .category:
            return true
        }
    }
}

/// Encodes FamilyControls tokens/selections with the same JSON configuration
/// used by LocalAliasStore's token helpers, then wraps the bytes as base64.
enum AppCatalogBlobEncoder {
    enum EncodeError: Error {
        case failed
    }

    static func base64<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            throw EncodeError.failed
        }
        return data.base64EncodedString()
    }
}

/// App Store/catalog match chosen by the parent while labeling one opaque
/// FamilyControls app token.
struct CatalogSearchResult: Equatable, Identifiable, Sendable {
    let canonicalName: String
    let bundleID: String?
    let aliases: [String]
    let artworkURL: URL?

    init(
        canonicalName: String,
        bundleID: String?,
        aliases: [String],
        artworkURL: URL? = nil
    ) {
        self.canonicalName = canonicalName
        self.bundleID = bundleID
        self.aliases = aliases
        self.artworkURL = artworkURL
    }

    var id: String {
        bundleID ?? canonicalName.lowercased()
    }
}

struct AppleScreenTimeCategorySuggestion: Equatable, Identifiable, Sendable {
    let semanticKey: String
    let displayName: String
    let aliases: [String]

    var id: String { semanticKey }

    static let social = AppleScreenTimeCategorySuggestion(
        semanticKey: "social",
        displayName: "Social",
        aliases: ["social", "social networking", "social media", "社交"]
    )
    static let games = AppleScreenTimeCategorySuggestion(
        semanticKey: "games",
        displayName: "Games",
        aliases: ["games", "game", "游戏", "遊戲"]
    )
    static let entertainment = AppleScreenTimeCategorySuggestion(
        semanticKey: "entertainment",
        displayName: "Entertainment",
        aliases: ["entertainment", "entertain", "streaming", "tv", "video", "娱乐", "娛樂"]
    )
    static let creativity = AppleScreenTimeCategorySuggestion(
        semanticKey: "creativity",
        displayName: "Creativity",
        aliases: ["creativity", "creative", "photo", "video editing", "design", "创意", "創意"]
    )
    static let productivityAndFinance = AppleScreenTimeCategorySuggestion(
        semanticKey: "productivity",
        displayName: "Productivity & Finance",
        aliases: ["productivity", "finance", "productivity & finance", "效率", "生产力", "生產力", "财务", "財務"]
    )
    static let education = AppleScreenTimeCategorySuggestion(
        semanticKey: "education",
        displayName: "Education",
        aliases: ["education", "learning", "school", "study", "教育", "学习", "學習"]
    )
    static let informationAndReading = AppleScreenTimeCategorySuggestion(
        semanticKey: "reading",
        displayName: "Information & Reading",
        aliases: ["information", "reading", "information & reading", "books", "news", "reference", "信息", "资讯", "資訊", "阅读", "閱讀", "图书", "圖書"]
    )
    static let healthAndFitness = AppleScreenTimeCategorySuggestion(
        semanticKey: "health",
        displayName: "Health & Fitness",
        aliases: ["health", "fitness", "health & fitness", "wellness", "健康", "健身"]
    )
    static let shoppingAndFood = AppleScreenTimeCategorySuggestion(
        semanticKey: "shopping",
        displayName: "Shopping & Food",
        aliases: ["shopping", "food", "shopping & food", "delivery", "购物", "購物", "美食", "外卖", "外賣"]
    )
    static let travel = AppleScreenTimeCategorySuggestion(
        semanticKey: "travel",
        displayName: "Travel",
        aliases: ["travel", "navigation", "maps", "交通", "旅行", "导航", "導航"]
    )
    static let utilities = AppleScreenTimeCategorySuggestion(
        semanticKey: "utilities",
        displayName: "Utilities",
        aliases: ["utilities", "utility", "tools", "工具", "实用工具", "實用工具"]
    )
    static let other = AppleScreenTimeCategorySuggestion(
        semanticKey: "other",
        displayName: "Other",
        aliases: ["other", "misc", "miscellaneous", "其他"]
    )
}

enum AppleScreenTimeCategorySuggestions {
    static let all: [AppleScreenTimeCategorySuggestion] = [
        .social,
        .games,
        .entertainment,
        .creativity,
        .productivityAndFinance,
        .education,
        .informationAndReading,
        .healthAndFitness,
        .shoppingAndFood,
        .travel,
        .utilities,
        .other,
    ]

    static func matches(for query: String) -> [AppleScreenTimeCategorySuggestion] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "category" else { return all }
        return all.filter { suggestion in
            suggestion.displayName.lowercased().contains(normalized)
                || suggestion.semanticKey.contains(normalized)
                || suggestion.aliases.contains { $0.lowercased().contains(normalized) }
        }
    }

    static func visibleCapsules(for query: String) -> [AppleScreenTimeCategorySuggestion] {
        all
    }

    static func exactMatch(for value: String) -> AppleScreenTimeCategorySuggestion? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return all.first { suggestion in
            suggestion.displayName.lowercased() == normalized
                || suggestion.semanticKey.lowercased() == normalized
                || suggestion.aliases.contains { $0.lowercased() == normalized }
        }
    }
}

/// Save-attempt state for capture sheets. Invalid rows are surfaced in place;
/// they are never filtered out to create a misleading partial save.
struct CaptureSheetModel: Equatable, Sendable {
    var rows: [PendingAppRow]
    var isPresented: Bool
    private(set) var errorBanner: String?
    private(set) var highlightedRows: [Int]
    private(set) var savedRows: [PendingAppRow]

    init(rows: [PendingAppRow], isPresented: Bool = true) {
        self.rows = rows
        self.isPresented = isPresented
        self.errorBanner = nil
        self.highlightedRows = []
        self.savedRows = []
    }

    mutating func attemptSave() {
        let invalidRows = rows.enumerated()
            .compactMap { index, row in row.isLockableApp ? nil : index }

        guard rows.isEmpty == false else {
            isPresented = true
            errorBanner = "Pick an app first"
            highlightedRows = []
            savedRows = []
            return
        }

        guard invalidRows.isEmpty else {
            isPresented = true
            errorBanner = Self.unlabeledMessage(count: invalidRows.count)
            highlightedRows = invalidRows
            savedRows = []
            return
        }

        isPresented = false
        errorBanner = nil
        highlightedRows = []
        savedRows = rows
    }

    private static func unlabeledMessage(count: Int) -> String {
        count == 1 ? "1 app still needs a name" : "\(count) apps still need names"
    }
}

/// State for one pending app token returned by an Add App capture.
///
/// The FamilyActivityPicker can return multiple app tokens, categories, and web
/// domains. Add App promotes every app-token row only after the parent binds it
/// to a catalog entry and explicitly confirms the visual `Label(token)` match.
struct PendingAppRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let tokenBase64: String
    let tokenAvailable: Bool
    private(set) var boundEntry: CatalogSearchResult?
    private(set) var confirmed: Bool

    init(rowID: UUID = UUID(), tokenBase64: String, tokenAvailable: Bool = true) {
        self.id = rowID
        self.tokenBase64 = tokenBase64
        self.tokenAvailable = tokenAvailable
        self.boundEntry = nil
        self.confirmed = false
    }

    var isLockableApp: Bool {
        tokenAvailable && confirmed && boundEntry != nil
    }

    mutating func bind(_ entry: CatalogSearchResult) {
        boundEntry = entry
        confirmed = false
    }

    mutating func confirm() {
        guard boundEntry != nil else { return }
        confirmed = true
    }

    func makeUploadApp(sourceDeviceID: UUID?) -> ChildAppCatalogUploadApp? {
        guard isLockableApp, let entry = boundEntry else { return nil }
        return ChildAppCatalogUploadApp(
            // A fresh capture has no backend alias_key yet. The backend treats a
            // non-nil alias_key as "update this existing row" and returns 404 for
            // an id it doesn't recognize (test_upload_with_unknown_alias_key_returns_404).
            // `id` is a LOCAL-only handle, never a backend key — send nil so the
            // backend matches/creates by natural key (display + bundle).
            aliasKey: nil,
            displayName: entry.canonicalName,
            tokenKind: "app",
            bundleID: entry.bundleID,
            aliases: Self.aliases(for: entry),
            tokenAvailable: tokenAvailable,
            tokenDataBase64: tokenBase64,
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func aliases(for entry: CatalogSearchResult) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in [entry.canonicalName, entry.bundleID].compactMap({ $0 }) + entry.aliases {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

/// State for one broad-coverage Apple Screen Time category token.
///
/// Categories intentionally have no bundle id or app artwork: they are resolved
/// only by category name/alias and cover current plus future apps in that
/// Apple category.
struct PendingCategoryRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var semanticKey: String
    var displayName: String
    let tokenBase64: String

    init(rowID: UUID = UUID(), semanticKey: String, displayName: String, tokenBase64: String) {
        self.id = rowID
        self.semanticKey = semanticKey
        self.displayName = displayName
        self.tokenBase64 = tokenBase64
    }

    var isNamedCategory: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func initialDisplayName(pickerLabel: String?) -> String {
        pickerLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    mutating func applySuggestion(_ suggestion: AppleScreenTimeCategorySuggestion) {
        semanticKey = suggestion.semanticKey
        displayName = suggestion.displayName
    }

    func matchesSuggestion(_ suggestion: AppleScreenTimeCategorySuggestion) -> Bool {
        semanticKey == suggestion.semanticKey
            && displayName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(suggestion.displayName) == .orderedSame
    }

    func makeUploadCategory(sourceDeviceID: UUID?) -> ChildAppCatalogUploadApp {
        ChildAppCatalogUploadApp(
            // See makeUploadApp: `id` is a local-only handle; never send it as a
            // backend alias_key (the backend 404s on unknown ids). nil = create/
            // match by natural key.
            aliasKey: nil,
            displayName: displayName,
            tokenKind: "category",
            bundleID: nil,
            aliases: Self.aliases(displayName: displayName, semanticKey: semanticKey),
            tokenAvailable: true,
            tokenDataBase64: tokenBase64,
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func aliases(displayName: String, semanticKey: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in [displayName, semanticKey] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

/// Validates the App Controls v2 combined FamilyActivityPicker selection, which
/// keeps BOTH apps and categories (unlike the single-mode `CapturePathValidator`).
/// Rules: empty → invalid; any web domains → invalid; apps and/or categories → valid.
enum CombinedPickerValidator {
    struct Result: Equatable { let isValid: Bool; let reason: Reason? }
    enum Reason: String, Equatable {
        case empty = "Pick at least one app or category."
        case webNotSupported = "Websites aren't supported here. Remove website selections."
    }
    static func validate(_ c: SelectionCounts) -> Result {
        if c.webDomainTokens > 0 { return Result(isValid: false, reason: .webNotSupported) }
        if c.applicationTokens == 0 && c.categoryTokens == 0 { return Result(isValid: false, reason: .empty) }
        return Result(isValid: true, reason: nil)
    }
}
