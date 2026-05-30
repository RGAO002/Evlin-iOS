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
