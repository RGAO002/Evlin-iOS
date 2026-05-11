import Foundation
import FamilyControls
import ManagedSettings

/// Bridges **Home Settings › Managed Apps** choices into **`LocalAliasStore`** so Chat
/// commands like `"lock entertainment"` (`category_hint: entertainment`) resolve a token on
/// the **kid device** (`ActionExecutor` → `LocalAliasStore.categoryToken(forName:)`).
///
/// Onboarding `CategoryDefaultsStep` still establishes the authoritative mapping when used;
/// this sync avoids the “picked Entertainment in Managed Apps but Chat says not configured” gap.
enum SemanticCategoryAliasSync {

    /// For each picker-reported category with both a token and a display name we can classify,
    /// persist under the semantic key Chat / the backend emits (`games`, `social`, `entertainment`, …).
    static func syncChatAliases(from selection: FamilyActivitySelection) {
        for cat in selection.categories {
            guard let token = cat.token else { continue }
            persistSemanticAndDisplayAliases(token: token, displayName: cat.localizedDisplayName)
        }
    }

    /// Re-applies semantic + literal keys when metadata arrays are missing (e.g. after plist decode)
    /// but the token blob still matches a prior Managed Apps picker session.
    static func persistSemanticAndDisplayAliases(token: ActivityCategoryToken, displayName: String?) {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed, !name.isEmpty {
            LocalAliasStore.shared.saveCategoryToken(token, forName: name)
        }
        if let key = inferredSemanticKey(localizedDisplayName: trimmed) {
            LocalAliasStore.shared.saveCategoryToken(token, forName: key)
        }
    }

    /// Debug / inspector: which English semantic key Chat may use for this picker label, if any.
    static func semanticAliasKey(forPickerLabel: String?) -> String? {
        let trimmed = forPickerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = trimmed, !name.isEmpty else { return nil }
        return inferredSemanticKey(localizedDisplayName: name)
    }

    /// Matches Apple’s picker `localizedDisplayName` across locales (English + common
    /// Simplified / Traditional Chinese). Chat still emits English keys (`entertainment`, …).
    private static func inferredSemanticKey(localizedDisplayName: String?) -> String? {
        guard let name = localizedDisplayName, !name.isEmpty else { return nil }
        let raw = name.lowercased()

        func hasAny(_ needles: String...) -> Bool {
            needles.contains { raw.contains($0.lowercased()) }
        }

        func hasAnyChar(_ needles: String...) -> Bool {
            needles.contains { name.contains($0) }
        }

        // More specific English fragments before broad ones where order matters.
        // English "social" last among social checks — catches short labels without "social network".
        if hasAny("social network", "social media", "social") || hasAnyChar("社交") {
            return "social"
        }
        if hasAny("game") || hasAnyChar("游戏", "遊戲") {
            return "games"
        }
        if hasAny("entertain", "streaming", "tv & video", "streaming & leisure")
            || hasAnyChar("娱乐", "娛樂") {
            return "entertainment"
        }
        if hasAny("education", "learning", "reading & reference", "books")
            || hasAnyChar("教育", "学习", "學習", "图书", "圖書", "阅读", "閱讀") {
            return "education"
        }
        if hasAny("productivity", "finance") || hasAnyChar("生产力", "生產力", "效率", "财务", "財務", "财经", "財經") {
            return "productivity"
        }
        return nil
    }
}
