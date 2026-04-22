import Foundation

enum ReceiptState: Sendable, Equatable {
    case pending
    case confirmedExact(displayName: String, unlocksAt: Date?)
    case confirmedFallback(displayName: String, category: String, origRequest: String)
    case failedPermission
    case failedListNotFound(listName: String)
    case failedCategoryNotConfigured(category: String)
    case failedTimeout
    case failedOther(reason: String)
}
