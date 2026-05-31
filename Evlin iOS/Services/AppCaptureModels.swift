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
/// domains. Add App only promotes one app-token row after the parent binds it to
/// a catalog entry and explicitly confirms the visual `Label(token)` match.
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
            aliasKey: id,
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
    let semanticKey: String
    let displayName: String
    let tokenBase64: String

    init(rowID: UUID = UUID(), semanticKey: String, displayName: String, tokenBase64: String) {
        self.id = rowID
        self.semanticKey = semanticKey
        self.displayName = displayName
        self.tokenBase64 = tokenBase64
    }

    func makeUploadCategory(sourceDeviceID: UUID?) -> ChildAppCatalogUploadApp {
        ChildAppCatalogUploadApp(
            aliasKey: id,
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
