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

    /// Currently-rendered confirmation card, if any. See plan Phase 9.
    /// Set when backend returns `action.card_id`, cleared when user answers.
    @Published var currentCard: (CardID, CardContext, CardHandlers)?

    let quickPrompts = QuickPrompt.defaults
    var apiClient: APIClient = APIClient()
    var childName: String = "Liam"
    /// "std" | "max" — drives E1 copy branching. Read from UserDefaults at sendMessage time.
    private var protectionMode: String {
        UserDefaults.standard.string(forKey: "evlin.protectionMode") ?? "std"
    }

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

                // New v2 shape: response.action is a structured ChatActionResponse.
                // Phase 9 — if dispatcher returned a card_id, render the card instead.
                if let act = response.action, let cardIDStr = act.card_id, let cardID = CardID(rawValue: cardIDStr) {
                    let context = CardContext(
                        targetDisplay: act.target_display ?? "",
                        childName: self.childName,
                        durationMinutes: act.duration_minutes,
                        categoryGuess: act.category_guess,
                        listSuggestions: act.list_suggestions ?? [],
                        existingLists: [],
                        blockItems: [],
                        childDevices: [],
                        mode: self.protectionMode,
                        existingRecordKey: nil,
                        requestedExpiryISO: nil,
                        existingMode: nil
                    )
                    let handlers = CardHandlers(
                        onPrimary: { [weak self] in
                            self?.handleCardPrimary(cardID: cardID, action: act)
                        },
                        onCancel: { [weak self] in self?.currentCard = nil },
                        onDurationPicked: { [weak self] mins in
                            self?.handleDurationPicked(mins, action: act)
                        }
                    )
                    messages.append(ChatMessage(
                        role: .agent, content: response.message,
                        timestamp: Date(), reasoning: response.reasoning, action: nil
                    ))
                    self.currentCard = (cardID, context, handlers)
                    self.isThinking = false
                    return
                }

                // Legacy shape fallback (v1 `action.type` direct) — the new backend
                // emits ChatActionResponse but the ChatAction enum here still drives
                // the legacy lock-card UI.
                if let act = response.action {
                    let duration = act.duration_minutes ?? 30
                    switch act.type {
                    case "shield", "lock":
                        action = .lockDevice(minutes: duration, childName: childName)
                    case "unshield", "unshield_all", "unblock", "unblock_all", "unlock", "unlock_all":
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

    // MARK: - Card handlers (Phase 9)

    /// Handle the primary button on a confirmation card. Most cards re-send
    /// /parent/chat with either force_confirmations or a clarified phrasing.
    private func handleCardPrimary(cardID: CardID, action: APIClient.ChatActionResponse) {
        switch cardID {
        case .A1:
            resendWithForce(["A1"])
        case .B1:
            resendWithForce(["B1"])
        case .E1:
            // E1 primary = "Shield <category> instead". Rewrite the parent's
            // original request into a category-shaped phrase and re-send. Use
            // categoryGuess from the backend's DispatchResult.
            let cat = action.category_guess ?? "social"
            let durSuffix = action.duration_minutes.map { " for \($0) minutes" } ?? ""
            resendWithPhrase("shield \(cat) apps\(durSuffix)")
        default:
            print("[ChatViewModel] Card primary for \(cardID.rawValue) — stub")
            currentCard = nil
        }
    }

    /// Re-send the original user message verbatim + force_confirmations.
    private func resendWithForce(_ forceIDs: [String]) {
        guard let originalMsg = messages.reversed().first(where: { $0.role == .parent })?.content
        else { currentCard = nil; return }
        resend(message: originalMsg, forceConfirmations: forceIDs)
    }

    /// Re-send with a brand-new phrase (for rewrites like E1 → category shield).
    private func resendWithPhrase(_ phrase: String) {
        resend(message: phrase, forceConfirmations: [])
    }

    private func resend(message: String, forceConfirmations: [String]) {
        currentCard = nil
        // Echo the rewritten intent as a parent message so the user sees what we sent.
        messages.append(ChatMessage(role: .parent, content: message, timestamp: Date()))
        isThinking = true

        Task {
            let history: [[String: String]] = messages.suffix(10).map { msg in
                ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
            }
            do {
                let resp = try await apiClient.sendChatMessage(
                    message: message,
                    childName: childName,
                    history: history,
                    forceConfirmations: forceConfirmations
                )
                await MainActor.run {
                    // Re-enter the normal response handler by re-using the same
                    // card-rendering / action-translation code path. Easiest:
                    // append the agent text + if backend returned a new card_id,
                    // render it; else log and move on.
                    if let act = resp.action,
                       let cardIDStr = act.card_id,
                       let cardID = CardID(rawValue: cardIDStr) {
                        let context = CardContext(
                            targetDisplay: act.target_display ?? "",
                            childName: self.childName,
                            durationMinutes: act.duration_minutes,
                            categoryGuess: act.category_guess,
                            listSuggestions: act.list_suggestions ?? [],
                            existingLists: [], blockItems: [], childDevices: [],
                            mode: self.protectionMode,
                            existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil
                        )
                        let handlers = CardHandlers(
                            onPrimary: { [weak self] in self?.handleCardPrimary(cardID: cardID, action: act) },
                            onCancel: { [weak self] in self?.currentCard = nil },
                            onDurationPicked: { [weak self] mins in self?.handleDurationPicked(mins, action: act) }
                        )
                        self.messages.append(ChatMessage(
                            role: .agent, content: resp.message, timestamp: Date(),
                            reasoning: resp.reasoning, action: nil
                        ))
                        self.currentCard = (cardID, context, handlers)
                    } else {
                        self.messages.append(ChatMessage(
                            role: .agent, content: resp.message, timestamp: Date(),
                            reasoning: resp.reasoning, action: nil
                        ))
                    }
                    self.isThinking = false
                }
            } catch {
                await MainActor.run {
                    self.messages.append(ChatMessage(
                        role: .agent,
                        content: "Sorry, I couldn't reach the server. Try again?",
                        timestamp: Date()
                    ))
                    self.isThinking = false
                }
                print("[ChatViewModel] resend failed: \(error)")
            }
        }
    }

    /// D1 quick-pick — resend with duration filled in.
    private func handleDurationPicked(_ mins: Int?, action: APIClient.ChatActionResponse) {
        guard let originalMsg = messages.reversed().first(where: { $0.role == .parent })?.content
        else { currentCard = nil; return }
        currentCard = nil
        let durStr = mins.map { "for \($0) minutes" } ?? "permanently"
        let refined = "\(originalMsg) \(durStr)"
        Task {
            let history: [[String: String]] = messages.suffix(10).map { msg in
                ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
            }
            do {
                let resp = try await apiClient.sendChatMessage(
                    message: refined, childName: childName, history: history
                )
                await MainActor.run {
                    self.messages.append(ChatMessage(
                        role: .agent, content: resp.message, timestamp: Date(),
                        reasoning: resp.reasoning, action: nil
                    ))
                }
            } catch {
                print("[ChatViewModel] duration-pick resend failed: \(error)")
            }
        }
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
