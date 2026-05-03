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

    /// In-flight ack-status polls, keyed by command_id. Cancelled on clearHistory
    /// or when a terminal status is received.
    private var activePolls: [UUID: Task<Void, Never>] = [:]

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

        messages.append(ChatMessage(role: .parent, content: text, timestamp: Date()))
        inputText = ""
        isThinking = true
        errorMessage = nil

        dispatchChat(userMessage: text, forceConfirmations: [])
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

    // MARK: - Chat pipeline (Phase 9 — unified)

    /// Single entry point for every outbound /parent/chat call.
    /// Handles three response shapes:
    ///   1. `card_id` set → render a confirmation card, wire its handlers.
    ///   2. `command_id` set → append agent bubble, start ack-status poll that
    ///      mutates the bubble's receiptState when the child acks.
    ///   3. plain text → append agent bubble, done.
    /// `userMessage` is the parent-visible text that produced this call.
    /// When the dispatcher rewrites the message (card → resend), the new parent
    /// bubble is appended BEFORE calling this so history ordering is correct.
    private func dispatchChat(userMessage: String, forceConfirmations: [String]) {
        let history: [[String: String]] = messages.suffix(10).map { msg in
            ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let resp = try await self.apiClient.sendChatMessage(
                    message: userMessage,
                    childName: self.childName,
                    history: history,
                    forceConfirmations: forceConfirmations
                )
                await MainActor.run { self.processResponse(resp, userMessage: userMessage) }
            } catch {
                await MainActor.run {
                    let detail: String
                    if let api = error as? APIError, case .serverError(let code) = api, code == 500 || code == 503 {
                        detail = "The AI model is briefly overloaded. Please tap again in a few seconds."
                    } else {
                        detail = "I'm unable to connect right now. Please check your network connection and try again."
                    }
                    self.messages.append(ChatMessage(role: .agent, content: detail, timestamp: Date()))
                    self.errorMessage = error.localizedDescription
                    self.isThinking = false
                }
            }
        }
    }

    @MainActor
    private func processResponse(_ resp: APIClient.ChatResponse, userMessage: String) {
        // 1. Card rendering
        if let act = resp.action, let cardIDStr = act.card_id, let cardID = CardID(rawValue: cardIDStr) {
            messages.append(ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            ))
            renderCard(cardID: cardID, action: act)
            isThinking = false
            return
        }

        // 2. Queued command — append bubble + start ack poll.
        // Note: no longer sets msg.lockMinutes/lockChildName — the legacy
        // LockConfirmationCard was mock UI ("Liam's device has been restricted")
        // that lied about execution state. ReceiptCard is now the single honest
        // source of truth; if the child fails (not authorized, category not
        // configured, etc.), the receipt shows the real error.
        if let act = resp.action, let cmdID = act.command_id {
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            )
            msg.commandID = cmdID
            msg.receiptState = .pending
            messages.append(msg)
            startAckPoll(
                commandID: cmdID,
                messageID: msg.id,
                targetDisplay: act.target_display,
                expiresAt: act.duration_minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
            )
            isThinking = false
            return
        }

        // 2.5 Agent envelope (Phase D/E). When AGENT_ENABLED=1 the backend may
        // return staged proposals and/or executed receipts. Append a single
        // bubble carrying both; ChatView renders ProposalCard / ReceiptBubble
        // beneath. Strictly opt-in — only fires when at least one is non-empty,
        // so existing card_id / command_id / shield-block flows are untouched.
        if (resp.proposals?.isEmpty == false) || (resp.receipts?.isEmpty == false) {
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil
            )
            msg.proposals = resp.proposals
            msg.receipts = resp.receipts
            messages.append(msg)
            isThinking = false
            return
        }

        // 3. Plain text (conversational reply, or confirmation_required without card_id)
        var msg = ChatMessage(
            role: .agent, content: resp.message, timestamp: Date(),
            reasoning: resp.reasoning, action: nil
        )
        // Restore safety-card heuristic that was lost in d86772c refactor.
        // When the parent asks "is X safe", "where is X", or "X's location",
        // attach the SafetyStatusCard + SafetyActionButtons (location pin +
        // call) to the agent's reply. The card is rendered by ChatView when
        // isSafetyCard == true.
        let lowered = userMessage.lowercased()
        if lowered.contains("safe") || lowered.contains("where") || lowered.contains("location") {
            msg.isSafetyCard = true
        }
        messages.append(msg)
        isThinking = false
    }

    @MainActor
    private func renderCard(cardID: CardID, action act: APIClient.ChatActionResponse) {
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
            onSecondary: { [weak self] in self?.handleCardSecondary(cardID: cardID, action: act) },
            onTertiary: { [weak self] in self?.handleCardTertiary(cardID: cardID, action: act) },
            onCancel: { [weak self] in self?.currentCard = nil },
            onDurationPicked: { [weak self] mins in self?.handleDurationPicked(mins, action: act) },
            onChildrenPicked: { [weak self] ids in self?.handleChildrenPicked(ids, action: act) },
            onChildrenLabelsPicked: { [weak self] labels in self?.handleChildrenLabelsPicked(labels, action: act) },
            onListPicked: { [weak self] name in self?.handleListPicked(name, action: act) }
        )
        self.currentCard = (cardID, context, handlers)
    }

    // MARK: - Card button handlers (P1-2 fix — no more dead slots)

    private func handleCardPrimary(cardID: CardID, action: APIClient.ChatActionResponse) {
        switch cardID {
        case .A1: resendWithForce(["A1"])
        case .A3: resendWithForce(["A3"])   // "Unblock all N" — dispatcher bypasses A3 guard
        case .B1: resendWithForce(["B1"])
        case .D3: resendWithForce(["D3"])   // "Confirm long duration" — dispatcher bypasses D3 guard

        case .D2:
            // "Lock ALL apps on <child>'s phone" — rewrite to kind=all shield.
            let durSuffix = action.duration_minutes.map { " for \($0) minutes" } ?? " for 30 minutes"
            resendWithPhrase("shield everything\(durSuffix)")

        case .E1, .E3:
            // Both: "Shield <category> instead" — rewrite to category-shaped phrase.
            let cat = action.category_guess ?? "social"
            let durSuffix = action.duration_minutes.map { " for \($0) minutes" } ?? ""
            resendWithPhrase("shield \(cat) apps\(durSuffix)")

        case .D4:
            // Checkbox confirm — the card's primary tap reads selected IDs out of
            // the card view itself. MissingInfoCard doesn't plumb the state back
            // yet; until that's wired, the primary button falls through to a
            // user-visible hint.
            showComingSoon(cardID, note: "Multi-child selection UI isn't fully wired yet — include the child's name in your message, e.g. \"lock Liam's phone for 30 min\".")

        case .D1:
            // D1 primary should never fire — D1 only has duration buttons (onDurationPicked).
            currentCard = nil

        case .B2:
            // "Switch from block to shield" — requires child-state awareness in
            // addBlock to return pending_confirmation. Not built yet.
            showComingSoon(cardID, note: "Block→shield switching isn't fully wired yet. Manually unblock, then shield.")

        case .C1:
            // "Replace shield with permanent block" — same: needs child-state logic.
            showComingSoon(cardID, note: "Shield→block replacement isn't fully wired yet. Manually unshield, then block.")

        case .C2:
            // "Block app in shielded list" — same: needs child-state logic.
            showComingSoon(cardID, note: "Blocking an app inside a shielded list isn't fully wired yet.")

        case .E2:
            // "Upgrade to Max" primary — goes to upgrade flow (not built).
            showComingSoon(cardID, note: "Upgrade flow is coming soon.")

        case .E4:
            // "Create list on child phone" — needs deep link to child's list picker.
            showComingSoon(cardID, note: "Creating Saved Lists from Chat isn't wired yet. Open the child phone's Settings → Evlin → Saved Lists.")

        case .F1:
            // F1's real action is list-pick (via onListPicked, already wired).
            // Primary fires only in degenerate zero-suggestion case.
            currentCard = nil

        case .G1:
            // "Set up Child Apple ID" — opens iOS Settings at best. Not wired.
            showComingSoon(cardID, note: "Child Apple ID setup happens in iOS Settings → Family Sharing.")

        case .R1:
            // Reflection confirmation. Resend the original parent message
            // with force=["R1"] so the backend's reflect path skips the
            // confirmation gate and actually fires.
            resendWithForce(["R1"])
        }
    }

    /// Clear the card and post a visible agent message explaining why the tap
    /// didn't execute. Better than silent failure.
    @MainActor
    private func showComingSoon(_ cardID: CardID, note: String) {
        currentCard = nil
        messages.append(ChatMessage(
            role: .agent,
            content: note,
            timestamp: Date()
        ))
    }

    private func handleCardSecondary(cardID: CardID, action: APIClient.ChatActionResponse) {
        switch cardID {
        case .A1:
            // "Shield for a while instead" — switch block → shield with default 30 min.
            let t = action.target_display ?? "that app"
            resendWithPhrase("shield \(t) for 30 minutes")
        case .D2:
            // "Just distracting categories" — common interpretation of "everything".
            let durSuffix = action.duration_minutes.map { " for \($0) minutes" } ?? " for 30 minutes"
            resendWithPhrase("shield distracting categories\(durSuffix)")
        case .D3:
            // "Change duration" — drop back to D1-style quick-pick.
            // Cheapest path: clear the D3 card and let user retype.
            currentCard = nil
            messages.append(ChatMessage(
                role: .agent,
                content: "Okay — how long should it be instead? Try e.g. \"for 30 minutes\" or \"for 2 hours\".",
                timestamp: Date()
            ))
        case .E1:
            // "Add to a Saved List" — MVP: direct the user to create it.
            currentCard = nil
            messages.append(ChatMessage(
                role: .agent,
                content: "You can create or edit Saved Lists from the child device's Settings. Once added, say \"shield <list name>\" here.",
                timestamp: Date()
            ))
        case .E2:
            // "Shield X instead" — switch block intent to shield.
            let t = action.target_display ?? "that app"
            resendWithPhrase("shield \(t) for 30 minutes")
        case .F1:
            // "Show all lists" — MVP stub.
            currentCard = nil
            messages.append(ChatMessage(
                role: .agent,
                content: "Here are your lists:\n" + (action.list_suggestions?.joined(separator: ", ") ?? "(none)"),
                timestamp: Date()
            ))
        default:
            print("[ChatViewModel] Card secondary for \(cardID.rawValue) — stub")
            currentCard = nil
        }
    }

    private func handleCardTertiary(cardID: CardID, action: APIClient.ChatActionResponse) {
        switch cardID {
        case .E1:
            // "Upgrade to Max" — MVP stub; real wiring goes to upgrade flow.
            currentCard = nil
            messages.append(ChatMessage(
                role: .agent,
                content: "Maximum mode unlocks remote single-app shields. Upgrade flow isn't built yet — coming soon.",
                timestamp: Date()
            ))
        default:
            print("[ChatViewModel] Card tertiary for \(cardID.rawValue) — stub")
            currentCard = nil
        }
    }

    /// D1 quick-pick — resend with duration filled in. Goes through the full
    /// response pipeline so the follow-up can itself produce a card/receipt.
    private func handleDurationPicked(_ mins: Int?, action: APIClient.ChatActionResponse) {
        guard let originalMsg = messages.reversed().first(where: { $0.role == .parent })?.content
        else { currentCard = nil; return }
        currentCard = nil
        let durStr = mins.map { "for \($0) minutes" } ?? "permanently"
        resendWithPhrase("\(originalMsg) \(durStr)")
    }

    /// F1 fuzzy-match list pick — resend as a direct shield on the chosen list.
    private func handleListPicked(_ name: String, action: APIClient.ChatActionResponse) {
        currentCard = nil
        let durSuffix = action.duration_minutes.map { " for \($0) minutes" } ?? " for 30 minutes"
        resendWithPhrase("shield \(name)\(durSuffix)")
    }

    /// D4 multi-child pick by UUID — placeholder; we currently use label-based
    /// routing (see handleChildrenLabelsPicked).
    private func handleChildrenPicked(_ ids: [UUID], action: APIClient.ChatActionResponse) {
        currentCard = nil
    }

    /// D4 primary confirm: user picked one or more child labels from the
    /// checkbox UI. Rewrite the last user message to include the first
    /// selected child's name so the backend dispatcher's hint matcher can
    /// route the command to that device. Multi-select is not yet supported
    /// (would require queueing one Command per child).
    private func handleChildrenLabelsPicked(_ labels: [String], action: APIClient.ChatActionResponse) {
        currentCard = nil
        guard !labels.isEmpty else {
            messages.append(ChatMessage(
                role: .agent,
                content: "Pick at least one child first.",
                timestamp: Date()
            ))
            return
        }
        guard let originalMsg = messages.reversed().first(where: { $0.role == .parent })?.content
        else { return }

        // Prepend the child's name if it's not already in the message.
        let primary = labels[0]
        let lowered = originalMsg.lowercased()
        let rewritten = lowered.contains(primary.lowercased())
            ? originalMsg
            : "\(primary)'s phone: \(originalMsg)"

        if labels.count > 1 {
            messages.append(ChatMessage(
                role: .agent,
                content: "Multi-child selection isn't supported yet — applying to \(primary) only.",
                timestamp: Date()
            ))
        }
        resendWithPhrase(rewritten)
    }

    private func resendWithForce(_ forceIDs: [String]) {
        guard let originalMsg = messages.reversed().first(where: { $0.role == .parent })?.content
        else { currentCard = nil; return }
        currentCard = nil
        isThinking = true
        dispatchChat(userMessage: originalMsg, forceConfirmations: forceIDs)
    }

    private func resendWithPhrase(_ phrase: String) {
        currentCard = nil
        messages.append(ChatMessage(role: .parent, content: phrase, timestamp: Date()))
        isThinking = true
        dispatchChat(userMessage: phrase, forceConfirmations: [])
    }

    // MARK: - Ack-status polling (P1-1 fix)

    /// Polls /parent/ack-status for a queued command and mutates the agent
    /// message's receiptState when the child acks. Times out at 30 s.
    private func startAckPoll(commandID: UUID, messageID: UUID, targetDisplay: String?, expiresAt: Date?) {
        let task = Task { [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let resp: AckStatusResponse
                do {
                    resp = try await self.apiClient.fetchRichAckStatus(commandID: commandID)
                } catch {
                    continue  // transient; retry next tick
                }

                let done = await MainActor.run { () -> Bool in
                    switch resp.status {
                    case "pending", "queued", "in_flight":
                        return false
                    case "confirmed", "confirmed_exact":
                        let verb = AckVerb(rawValue: resp.verb ?? "shield") ?? .shield
                        let name = resp.displayName ?? targetDisplay ?? ""
                        self.applyReceipt(
                            .confirmedExact(verb: verb, displayName: name, unlocksAt: expiresAt),
                            effective: resp.effectiveState,
                            messageID: messageID
                        )
                        return true
                    case "confirmed_fallback":
                        let verb = AckVerb(rawValue: resp.verb ?? "shield") ?? .shield
                        let name = resp.displayName ?? targetDisplay ?? ""
                        let cat = resp.category ?? "unknown"
                        let orig = resp.origRequest ?? targetDisplay ?? ""
                        self.applyReceipt(
                            .confirmedFallback(verb: verb, displayName: name, category: cat, origRequest: orig),
                            effective: resp.effectiveState,
                            messageID: messageID
                        )
                        return true
                    case "pending_confirmation":
                        // Child is asking for parent confirmation (B1-style).
                        if let pc = resp.pendingConfirmation, let cid = CardID(rawValue: pc.card_id) {
                            self.renderPendingConfirmationCard(cardID: cid, context: pc.context)
                        }
                        // Clear receipt placeholder — card takes over.
                        if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                            self.messages[idx].receiptState = nil
                        }
                        return true
                    case "failed":
                        // Map structured failure detail (from CommandPoller) to
                        // the specific ReceiptState case. ReceiptCard then renders
                        // a human copy instead of the raw Swift enum description.
                        let detail = resp.detail ?? [:]
                        let kind = (detail["reason"]?.value as? String) ?? "other"
                        let state: ReceiptState
                        switch kind {
                        case "not_authorized":
                            state = .failedPermission
                        case "list_not_found":
                            state = .failedListNotFound(
                                listName: (detail["list_name"]?.value as? String) ?? "(unknown)"
                            )
                        case "category_not_configured":
                            state = .failedCategoryNotConfigured(
                                category: (detail["category"]?.value as? String) ?? "(unknown)"
                            )
                        case "nothing_to_unlock":
                            state = .failedOther(reason: "Nothing matched to unlock.")
                        case "malformed":
                            state = .failedOther(reason: "The command wasn't well-formed.")
                        case "execution":
                            state = .failedOther(
                                reason: (detail["message"]?.value as? String) ?? "Execution failed."
                            )
                        default:
                            state = .failedOther(reason: kind)
                        }
                        self.applyReceipt(state, effective: nil, messageID: messageID)
                        return true
                    case "timeout":
                        self.applyReceipt(.failedTimeout, effective: nil, messageID: messageID)
                        return true
                    default:
                        return false
                    }
                }
                if done { return }
            }
            // Deadline hit without a terminal status
            await MainActor.run {
                self?.applyReceipt(.failedTimeout, effective: nil, messageID: messageID)
            }
        }
        activePolls[commandID] = task
    }

    @MainActor
    private func applyReceipt(_ state: ReceiptState, effective: AckEffectiveState?, messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].receiptState = state
        messages[idx].receiptEffectiveState = effective
    }

    @MainActor
    private func renderPendingConfirmationCard(cardID: CardID, context ctx: [String: String]) {
        let cardCtx = CardContext(
            targetDisplay: ctx["target_display"] ?? "",
            childName: self.childName,
            durationMinutes: Int(ctx["requested_duration_minutes"] ?? ""),
            categoryGuess: nil,
            listSuggestions: [],
            existingLists: [], blockItems: [], childDevices: [],
            mode: self.protectionMode,
            existingRecordKey: ctx["existing_record_key"],
            requestedExpiryISO: ctx["requested_expiry_iso"],
            existingMode: ctx["existing_mode"]
        )
        let fakeAction = APIClient.ChatActionResponse(
            type: "shield", command_id: nil, tier: nil,
            target_display: ctx["target_display"],
            duration_minutes: Int(ctx["requested_duration_minutes"] ?? ""),
            confirmation_required: true,
            card_id: cardID.rawValue,
            confirmation_reason: nil, list_suggestions: nil, category_guess: nil
        )
        let handlers = CardHandlers(
            onPrimary: { [weak self] in self?.handleCardPrimary(cardID: cardID, action: fakeAction) },
            onSecondary: { [weak self] in self?.handleCardSecondary(cardID: cardID, action: fakeAction) },
            onCancel: { [weak self] in self?.currentCard = nil }
        )
        self.currentCard = (cardID, cardCtx, handlers)
    }

    // MARK: - Fetch video recommendation

    // MARK: - Agent envelope handlers (Phase E)

    /// Parent tapped Confirm on a ProposalCard. POST /parent/agent/exec,
    /// then move the proposal to the receipts list on the same agent message
    /// so the card flips into a ReceiptBubble in place.
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let receipt = try await client.executeProposal(token: p.token)
            if let i = messages.lastIndex(where: { $0.role == .agent }) {
                var msg = messages[i]
                msg.proposals?.removeAll(where: { $0.token == p.token })
                msg.receipts = (msg.receipts ?? []) + [receipt]
                messages[i] = msg
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    /// Parent tapped Skip — drop the proposal from the most recent agent message.
    @MainActor
    func skipProposal(_ p: ProposalDTO) {
        if let i = messages.lastIndex(where: { $0.role == .agent }) {
            var msg = messages[i]
            msg.proposals?.removeAll(where: { $0.token == p.token })
            messages[i] = msg
        }
    }

    /// Parent tapped Undo on a ReceiptBubble. POST the revert and append a
    /// subtle confirmation bubble. Errors flow into errorMessage.
    @MainActor
    func undoReceipt(token: String) async {
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            _ = try await client.revertAction(actionID: token)
            messages.append(ChatMessage(role: .agent, content: "Reverted."))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

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
