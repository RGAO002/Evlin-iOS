import SwiftUI
import FamilyControls
import ManagedSettings

/// Render an app/category name with its real Apple icon when available,
/// SF Symbol fallback otherwise. The text part stays our own `Text` so
/// `.font` and `.foregroundColor` modifiers from the call-site work —
/// Apple's `Label(token)` text rendering ignores those.
///
/// Why a helper: ApplicationToken is opaque; only `Label(token)` can
/// render Apple's icon, and only `.labelStyle(.iconOnly)` strips the
/// ignored-style text part. Centralizes that two-step dance.
enum NameIconKind: String, Codable {
    case app
    case category
    case savedList
    case all
}

struct NameWithIcon: View {
    let name: String
    let kind: NameIconKind
    var artworkURL: URL? = nil
    var titleFont: Font = .body
    /// Draw a strikethrough on the name text. Used by U1Card to indicate a
    /// row that's hard-disabled because a broader shield (All Apps) covers
    /// it — the strike + greyed icon together signal "you can't unlock
    /// this alone". Off by default everywhere else.
    var strikethrough: Bool = false

    /// Icon URL resolved by-name as a fallback (see `.task` below). On the
    /// parent device there are no captured FamilyControls tokens, so
    /// `Label(token)` can't render the kid's app icons; when the backend also
    /// gave us no `artworkURL`, we look the icon up from iTunes by name.
    @State private var resolvedArtworkURL: URL? = nil

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 24, height: 24)
            Text(NameWithIcon.displayName(name))
                .font(titleFont)
                .strikethrough(strikethrough, color: nil)
        }
        .task(id: name) {
            // Only the app icon needs this, and only when we have neither a
            // backend artwork URL nor a local token to render (i.e. the parent
            // device). The kid device hits the `Label(token)` path instead.
            guard kind == .app,
                  artworkURL == nil,
                  resolvedArtworkURL == nil,
                  LocalAliasStore.shared.applicationToken(forLookupKey: name) == nil
            else { return }
            resolvedArtworkURL = await AppArtworkResolver.shared.artwork(
                forName: NameWithIcon.displayName(name)
            )
        }
    }

    /// Show the name with an uppercase first letter. `name` is preserved
    /// verbatim for icon-token lookup; only the rendered text is touched.
    /// Upgrade a routing-keyed name ("ig") to its user-facing display
    /// form ("Instagram"). Mirrors backend's
    /// `app.services.fastpath.intent_dictionary.BUILTIN_ALIASES` so the
    /// receipt card and the chat bubble agree on naming.
    ///
    /// Routing keys (`LocalAliasStore` lookups, `ActiveLockStore` keys)
    /// stay lowercase — only this display string is upgraded.
    /// Non-builtin names fall through to first-letter capitalization
    /// ("school apps" → "School apps") rather than `.capitalized`
    /// (which would title-case to "School Apps").
    static func displayName(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        let low = name.lowercased()
        if let formal = builtinAliasDisplayName[low] {
            return formal
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Map an iOS Screen Time category display name to a representative SF
    /// Symbol. Used on the parent device, which can't render Apple's category
    /// glyph (no captured token). Falls back to a generic grid.
    static func categorySymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("game") { return "gamecontroller.fill" }
        if n.contains("social") { return "person.2.fill" }
        if n.contains("entertain") { return "play.tv.fill" }
        if n.contains("educat") { return "graduationcap.fill" }
        if n.contains("creativ") { return "paintbrush.fill" }
        if n.contains("productiv") || n.contains("finance") { return "checklist" }
        if n.contains("health") || n.contains("fitness") { return "heart.fill" }
        if n.contains("music") { return "music.note" }
        if n.contains("news") { return "newspaper.fill" }
        if n.contains("photo") || n.contains("video") { return "photo.fill" }
        if n.contains("shop") || n.contains("food") { return "cart.fill" }
        if n.contains("travel") { return "airplane" }
        if n.contains("read") || n.contains("information") || n.contains("book") { return "book.fill" }
        if n.contains("sport") { return "sportscourt.fill" }
        if n.contains("utilit") { return "wrench.and.screwdriver.fill" }
        return "square.grid.2x2.fill"
    }

    /// MUST stay in sync with backend's `BUILTIN_ALIASES`. Adding here
    /// without the backend (or vice versa) means the chat bubble and
    /// the receipt card disagree on whether to say "Ig" or "Instagram".
    private static let builtinAliasDisplayName: [String: String] = [
        "ig": "Instagram",
        "insta": "Instagram",
        "fb": "Facebook",
        "tt": "TikTok",
        "yt": "YouTube",
        "wa": "WhatsApp",
        "sc": "Snapchat",
        "twit": "Twitter",
        "discord": "Discord",
    ]

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .app:
            if let artworkURL = artworkURL ?? resolvedArtworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    default:
                        Image(systemName: "app.fill")
                            .foregroundStyle(Color.evOutline)
                    }
                }
            } else if let token = LocalAliasStore.shared.applicationToken(forLookupKey: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(Color.evOutline)
            }
        case .category:
            if let token = LocalAliasStore.shared.categoryToken(forName: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                // Parent device has no captured category token, so Apple's
                // colored category glyph isn't renderable — pick a meaningful
                // SF Symbol by category name (Games → gamecontroller) instead of
                // a generic grid (and never an app artwork).
                Image(systemName: NameWithIcon.categorySymbol(for: name))
                    .foregroundStyle(Color.evOutline)
            }
        case .savedList:
            Image(systemName: "list.bullet.rectangle.fill")
                .foregroundStyle(Color.evOutline)
        case .all:
            Image(systemName: "iphone")
                .foregroundStyle(Color.evOutline)
        }
    }
}

/// Resolves an app's icon URL by display name via the public iTunes Search API,
/// with an in-memory + UserDefaults cache. Fallback for the PARENT device,
/// which has no captured FamilyControls tokens to render `Label(token)` and so
/// can't otherwise show a kid app's real icon when the backend gave no artwork
/// URL. App Store artwork is the same image `Label(token)` shows on the kid.
actor AppArtworkResolver {
    static let shared = AppArtworkResolver()

    private var memo: [String: URL] = [:]
    private let defaults = UserDefaults.standard
    private static let cachePrefix = "evlin.artworkByName."

    func artwork(forName name: String) async -> URL? {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let u = memo[key] { return u }
        if let s = defaults.string(forKey: Self.cachePrefix + key), let u = URL(string: s) {
            memo[key] = u
            return u
        }
        guard
            let q = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://itunes.apple.com/search?term=\(q)&entity=software&limit=1")
        else { return nil }
        guard
            let (data, resp) = try? await URLSession.shared.data(from: url),
            (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        struct ITunesResponse: Decodable {
            let results: [Item]
            struct Item: Decodable {
                let artworkUrl512: String?
                let artworkUrl100: String?
                let artworkUrl60: String?
            }
        }
        guard
            let decoded = try? JSONDecoder().decode(ITunesResponse.self, from: data),
            let first = decoded.results.first,
            let raw = first.artworkUrl512 ?? first.artworkUrl100 ?? first.artworkUrl60,
            let artURL = URL(string: raw)
        else { return nil }

        memo[key] = artURL
        defaults.set(raw, forKey: Self.cachePrefix + key)
        return artURL
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        NameWithIcon(name: "Instagram", kind: .app)
        NameWithIcon(name: "Entertainment", kind: .category)
        NameWithIcon(name: "Bedtime apps", kind: .savedList)
        NameWithIcon(name: "Whole phone", kind: .all)
    }
    .padding()
}
#endif
