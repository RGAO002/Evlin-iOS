import SwiftUI
import Combine
import FamilyControls

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
    private let screenTimeManager = ScreenTimeManager.shared

    private static let storageKey = "evlin_chat_history"

    private var clearObserver: Any?

    init() {
        loadMessages()
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
                    switch type {
                    case "lock":
                        let minutes = (actionDict["minutes"]?.value as? Int) ?? 30
                        action = .lockDevice(minutes: minutes, childName: childName)
                    case "unlock":
                        action = .unlockDevice(childName: childName)
                    default:
                        action = .none
                    }
                }

                if let action = action {
                    executeAction(action)
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
                messages.append(ChatMessage(
                    role: .agent,
                    content: "I'm unable to connect right now. Please check your network connection and try again.",
                    timestamp: Date()
                ))
            }

            isThinking = false
        }
    }

    // MARK: - Execute Screen Time actions

    private func executeAction(_ action: ChatAction) {
        switch action {
        case .lockDevice(let minutes, let childName):
            // Send to backend for child device to pick up
            sendToChildDevice(actionType: "lock", params: ["minutes": minutes, "child_name": childName])
        case .unlockDevice(let childName):
            sendToChildDevice(actionType: "unlock", params: ["child_name": childName])
        case .adjustRules:
            break
        case .none:
            break
        }
    }

    private func sendToChildDevice(actionType: String, params: [String: Any]) {
        let childId = UserDefaults.standard.string(forKey: "targetChildId") ?? ""
        print("[Parent] Sending \(actionType) to child: '\(childId)'")

        guard !childId.isEmpty else {
            print("[Parent] No targetChildId set — skipping")
            return
        }

        Task {
            guard let url = URL(string: "\(apiClient.baseURL)/parent/device-action") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "child_id": childId,
                "action_type": actionType,
                "params": params,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                print("[Parent] device-action response: \(http?.statusCode ?? 0) — \(String(data: data, encoding: .utf8) ?? "")")
            } catch {
                print("[Parent] device-action failed: \(error)")
            }
        }
    }

    func sendQuickPrompt(_ prompt: QuickPrompt) {
        inputText = prompt.text
        sendMessage()
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
