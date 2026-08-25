import Foundation

enum BigKidDisplayName {
    private static let placeholders: Set<String> = ["liam", "your kid"]

    static func resolve(server: String, local: String) -> String {
        let authoritative = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = local.trimmingCharacters(in: .whitespacesAndNewlines)

        if !authoritative.isEmpty,
           !placeholders.contains(authoritative.lowercased()) {
            return authoritative
        }

        return fallback.isEmpty ? "there" : fallback
    }
}
