
import Foundation

enum CommandAction: String, Codable, Sendable {
    case lock
    case unlock
    case unlockAll = "unlock_all"
    case expandLibrary = "expand_library"
}

struct CommandTarget: Codable, Sendable {
    var bundleID: String?
    var listName: String?
    var hasPendingBlob: Bool = false
    var categoryHint: String?
    var originalRequest: String
    var targetDisplay: String?
}

struct LockCommand: Codable, Sendable, Identifiable {
    let id: UUID                   // command_id
    let action: CommandAction
    let tier: LockTier?            // nil for unlock_all etc.
    let target: CommandTarget
    let durationMinutes: Int?      // nil = permanent
    let issuedAt: Date
    var expiresAt: Date? {
        guard let m = durationMinutes else { return nil }
        return issuedAt.addingTimeInterval(TimeInterval(m * 60))
    }
}

enum AckResult: Codable, Sendable, Equatable {
    case confirmedExact(displayName: String)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case failed(AckFailure)
}

enum AckFailure: Codable, Sendable, Equatable {
    case notAuthorized
    case listNotFound(String)
    case categoryNotConfigured(String)
    case nothingToUnlock
    case malformed
    case execution(String)
}
