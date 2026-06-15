import Foundation

/// Which Apple API backs this shield record.
/// See spec §3.1 for rationale.
enum ShieldTier: String, Codable, Sendable {
    case exactApp    // single app via ApplicationToken — Max only
    case savedList   // whole FamilyActivitySelection
    case category    // single category via ActivityCategoryToken
    case allApps     // shield.applicationCategories = .all(); web domain categories remain unset
    case all         // shield.applicationCategories = .all() + webDomainCategories = .all()
}
