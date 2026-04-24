import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet { saveMessages() }
    }
    @Published var inputText = ""
    @Published var isThinking = false
    @Published var errorMessage: String?

    let quickPrompts = QuickPrompt.defaults
    var apiClient: APIClient = APIClient()
    var childName: String = "Liam"

    private static let storageKey = "evlin_chat_history"

    private var clearObserver: Any?

    init() {
        loadMessages()
        // Re-seed if empty OR if the persisted strategy artifact is from an older
        // format (no videoId wired in). Bumps legacy chat history to the latest seed.
        let staleStrategy = messages.contains { $0.isStrategyArtifact && $0.videoId == nil }
        if messages.isEmpty || staleStrategy {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            messages = []
            seedInitialMessages()
        }
        clearObserver = NotificationCenter.default.addObserver(
            forName: .evlinClearChat, object: nil, queue: .main
        ) { [weak self] _ in
            self?.messages.removeAll()
        }
    }

    // MARK: - Persistence

    private func saveMessages() {
        // Keep last 50 messages
        let toSave = Array(messages.suffix(50))
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !saved.isEmpty else { return }
        messages = saved
    }

    func clearHistory() {
        messages.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Send

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(
            role: .parent,
            content: text,
            timestamp: Date()
        ))
        inputText = ""
        isThinking = true
        errorMessage = nil

        let history: [[String: String]] = messages.suffix(10).map { msg in
            ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
        }

        Task {
            do {
                let response = try await apiClient.sendChatMessage(
                    message: text,
                    childName: childName,
                    history: history
                )

                var action: ChatAction? = nil
                if let actionDict = response.action,
                   let type = actionDict["type"]?.value as? String {
                    let duration = (actionDict["duration_minutes"]?.value as? Int)
                        ?? (actionDict["minutes"]?.value as? Int)
                    switch type {
                    case "lock":
                        let minutes = duration ?? 30
                        action = .lockDevice(minutes: minutes, childName: childName)
                    case "lock_all":
                        let minutes = duration ?? 30
                        action = .lockDevice(minutes: minutes, childName: childName)
                    case "unlock":
                        action = .unlockDevice(childName: childName)
                    case "unlock_all":
                        action = .unlockDevice(childName: childName)
                    default:
                        action = ChatAction.none
                    }
                }

                var msg = ChatMessage(
                    role: .agent,
                    content: response.message,
                    timestamp: Date(),
                    reasoning: response.reasoning,
                    action: action
                )

                // Attach lock confirmation card
                if case .lockDevice(let mins, let name) = action {
                    msg.lockMinutes = mins
                    msg.lockChildName = name
                }

                // Attach safety card
                let lowered = text.lowercased()
                if lowered.contains("safe") || lowered.contains("where") || lowered.contains("location") {
                    msg.isSafetyCard = true
                }

                messages.append(msg)

                // Fetch video recommendation for lock actions
                if msg.lockMinutes != nil {
                    await fetchVideoRecommendation(for: msg.id)
                }
            } catch {
                errorMessage = error.localizedDescription
                let detail: String
                if let api = error as? APIError, case .serverError(let code) = api, code == 500 || code == 503 {
                    detail = "The AI model is briefly overloaded. Please tap again in a few seconds."
                } else {
                    detail = "I'm unable to connect right now. Please check your network connection and try again."
                }
                messages.append(ChatMessage(
                    role: .agent,
                    content: detail,
                    timestamp: Date()
                ))
            }

            isThinking = false
        }
    }

    func sendQuickPrompt(_ prompt: QuickPrompt) {
        inputText = prompt.text
        sendMessage()
    }

    // MARK: - Seed initial messages

    private func seedInitialMessages() {
        let now = Date()
        let m1 = ChatMessage(
            role: .agent,
            content: "I've confirmed the manual lock on Liam's device. Given his recent focus patterns, he may experience a frustration spike.",
            timestamp: now
        )
        var m2 = ChatMessage(
            role: .agent,
            content: "",
            timestamp: now
        )
        m2.strategyTitle = "Real-time De-escalation Strategy"
        m2.strategyStatus = "Locked"
        m2.strategyCategory = "Active Monitoring › Immediate Action"
        m2.strategyVideoLabel = "Managing Transition Frustration"
        m2.strategyVideoDuration = "3:00"
        m2.strategyTip = "If a tantrum occurs, use \"Planned Ignoring\". I've prepared a 30-second refresher for you."
        // Real YouTube video: "The Easy Way to Dramatically Reduce Toddler Tantrums"
        m2.videoId = "vaGT_FtWEQU"
        m2.videoThumbnail = "https://img.youtube.com/vi/vaGT_FtWEQU/maxresdefault.jpg"

        let m3 = ChatMessage(
            role: .agent,
            content: "Would you like to review the suggested de-escalation steps or watch the briefing video now?",
            timestamp: now
        )
        messages = [m1, m2, m3]
    }

    // MARK: - Fetch video recommendation

    private func fetchVideoRecommendation(for messageId: UUID) async {
        let base = apiClient.baseURL
        guard let url = URL(string: "\(base)/parent/youtube-recommendations?query=parenting+screen+time+transition+management&max_results=1") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let videos = try JSONDecoder().decode([YouTubeVideoDTO].self, from: data)
            if let v = videos.first,
               let idx = messages.firstIndex(where: { $0.id == messageId }) {
                messages[idx].videoTitle = v.title
                messages[idx].videoDescription = "This briefing outlines techniques to de-escalate potential friction after a screen time lock."
                messages[idx].videoThumbnail = v.thumbnail
                messages[idx].videoId = v.videoId
            }
        } catch {
            print("[Chat] Failed to fetch video: \(error)")
        }
    }

}

// DTO for YouTube API response
private struct YouTubeVideoDTO: Codable {
    let videoId: String
    let title: String
    let channel: String
    let thumbnail: String

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title, channel, thumbnail
    }
}
