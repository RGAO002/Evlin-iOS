import Combine
import Foundation

/// Parent-side bell feed client (notif spec §1.6 / Phase 3).
///
/// Reads the backend notification feed (`GET /notifications`, account-scoped via
/// the Keychain access token) and writes read/dismiss state back
/// (`PATCH /notifications/{id}/{action}`). The bell is a projection of the same
/// feed the pushes come from, so it is a superset of every visible push.
struct FeedNotification: Decodable, Identifiable, Equatable {
    let id: String          // recipient_id (stable per audience member)
    let eventId: String
    let childProfileId: String?
    let type: String
    let urgency: String
    let title: String?
    let body: String?
    let renderKey: String?
    let deepLink: [String: String]?
    let createdAt: String?
    let readAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, urgency, title, body
        case eventId = "event_id"
        case childProfileId = "child_profile_id"
        case renderKey = "render_key"
        case deepLink = "deep_link"
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    var isUnread: Bool { readAt == nil }
}

private struct FeedResponse: Decodable {
    let items: [FeedNotification]
    let nextCursor: String?
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case unreadCount = "unread_count"
    }
}

@MainActor
final class NotificationFeedClient: ObservableObject {
    @Published private(set) var items: [FeedNotification] = []
    @Published private(set) var unreadCount: Int = 0
    /// True when the newest event is newer than the last time the panel was
    /// opened — drives the bell's red dot (clears on open, returns on new).
    @Published private(set) var hasNew: Bool = false

    private let baseURL: String

    init(baseURL: String = "") {
        self.baseURL = baseURL.isEmpty ? APIClient().baseURL : baseURL
    }

    private var bearer: String? { KeychainStore.shared.load()?.accessToken }

    private func authed(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = bearer {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Pull the newest page of the bell feed. Failures leave the last list intact.
    func refresh() async {
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/notifications") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: authed(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(FeedResponse.self, from: data) else { return }
        self.items = decoded.items
        self.unreadCount = decoded.unreadCount
        self.recomputeHasNew()
    }

    /// Mark one recipient row read / opened / dismissed (best-effort write-back).
    func mark(_ recipientId: String, action: String) async {
        guard !baseURL.isEmpty,
              let url = URL(string: "\(baseURL)/notifications/\(recipientId)/\(action)") else { return }
        _ = try? await URLSession.shared.data(for: authed(url, method: "PATCH"))
    }

    /// Mark every currently-loaded unread row read, then refresh.
    func markAllRead() async {
        for n in items where n.isUnread {
            await mark(n.id, action: "read")
        }
        await refresh()
    }

    /// Dismiss one row: drop it from the list immediately (snappy, matches the
    /// original panel's ✕), then persist the dismiss to the backend.
    func dismiss(_ recipientId: String) async {
        items.removeAll { $0.id == recipientId }
        await mark(recipientId, action: "dismiss")
    }

    private static let lastOpenedKey = "evlin.notif.lastOpenedAt"

    /// Call when the bell panel is opened: clears the red dot and remembers the
    /// moment so only strictly-newer events re-light it.
    func markOpened() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastOpenedKey)
        hasNew = false
    }

    private func recomputeHasNew() {
        let last = UserDefaults.standard.double(forKey: Self.lastOpenedKey)
        let newest = items
            .compactMap { Self.parseDate($0.createdAt)?.timeIntervalSince1970 }
            .max() ?? 0
        hasNew = newest > last
    }

    private static func parseDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}
