import Foundation

enum LockTier: String, Codable, Sendable {
    case exactBundle = "exact_bundle"
    case savedList = "saved_list"
    case category = "category"
}
