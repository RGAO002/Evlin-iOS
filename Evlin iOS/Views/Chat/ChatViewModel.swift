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

    /// Currently-rendered confirmation card, if any. See plan Phase 9.
    /// Set when backend returns `action.card_id`, cleared when user answers.
    @Published var currentCard: (CardID, CardContext, CardHandlers)?

    /// ProposalToken → kind for proposals whose alias didn't resolve at
    /// pre-flight. Drives ProposalCard's "Tag <target>" UI and the
    /// hard guard inside `confirmProposal(_:)`. Task 2.3 wires up the
    /// pre-flight that populates this; here we declare it so the hard
    /// guard compiles.
    @Published var pendingAliasMisses: [String: AliasKind] = [:]

    /// Non-nil when ChatView should present the lazy-tag sheet.
    @Published var activeLazyTagRequest: LazyTagRequest? = nil

    // MARK: - Plan-arch dual-path

    /// FIFO queue of cards the backend returned in this turn. Strategy-agent
    /// responses can carry multiple cards (e.g. lock IG proposal + reflection
    /// question for the name-calling part of a compound message). UI renders
    /// queue.first, and when the user acts on it we removeFirst() so the next
    /// card slides in.
    @Published var pendingPlanArchCardQueue: [PlanArchCardPayload] = []

    /// Convenience: the card currently visible in the UI. Read-only;
    /// mutate via the queue. Kept as a property (not computed) so existing
    /// SwiftUI bindings (`$viewModel.pendingPlanArchCard`) still compile.
    @Published var pendingPlanArchCard: PlanArchCardPayload?

    /// True iff the most recent backend response came from the
    /// deterministic fastpath router (vs strategy_agent). Drives whether
    /// "This isn't what I meant" shows on the current card. Reset when
    /// the user sends a new message; updated on every chat response.
    @Published var lastResponseViaFastpath: Bool = false

    /// Lazy-tag sheets can come from the legacy ProposalDTO path or the new
    /// plan-arch card path. The plan-arch path must POST a plan-patch after
    /// saving the local alias; legacy only clears pendingAliasMisses.
    private var planArchLazyTagRequestIDs: Set<String> = []

    /// In-flight ack-status polls, keyed by command_id. Cancelled on clearHistory
    /// or when a terminal status is received.
    private var activePolls: [UUID: Task<Void, Never>] = [:]

    /// Captured at sendMessage time so U1 confirm handlers can re-send the
    /// original parent message with the marker appended.
    private var lastUserMessageForCard: String = ""

    /// Dedup reflection rows so polling doesn't stack duplicates.
    private var surfacedReflectionSubmissionIDs: Set<UUID> = []
    private var reflectionSubmissionPoll: AnyCancellable?

    private func currentClientAliasStateCodable() -> [String: [String]] {
        let activeAppTokens = ScreenTimeManager.shared.selectedApps.applicationTokens
        return [
            "known_apps": LocalAliasStore.shared.allActiveApplicationKeys(activeTokens: activeAppTokens),
            "known_categories": LocalAliasStore.shared.allCategoryNames()
        ]
    }

    private func currentClientAliasStateJSON() -> [String: Any] {
        currentClientAliasStateCodable()
    }

    private func currentFamilyAndChildIDs() -> (familyID: UUID?, childDeviceID: UUID?) {
        let familyID = UserDefaults.standard.string(forKey: "evlin.familyID").flatMap(UUID.init(uuidString:))
        let childID = UserDefaults.standard.string(forKey: "evlin.childDeviceID").flatMap(UUID.init(uuidString:))
        return (familyID, childID)
    }

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
            self?.surfacedReflectionSubmissionIDs.removeAll()
        }
        rebuildSurfacedReflectionSubmissionIndex()
        resumePendingAckPolls()
    }

    /// Re-attach ack-status polling for any persisted message still in
    /// `.pending`. Without this, the original poll task is orphaned when
    /// the VM dies (e.g. user toggled P↔K mode in single-device dev),
    /// leaving the receipt frozen on "Queued — waiting for kid device".
    /// Server holds the truth: cmd is either confirmed/failed by now (we
    /// flip to that immediately) or still pending (we poll for ≤90s, then
    /// .kidNotResponding).
    private func resumePendingAckPolls() {
        for msg in messages where msg.role == .agent
            && msg.receiptState == .pending
            && msg.commandID != nil {
            print("[AckPoll] resume cmd=\(msg.commandID!) msg=\(msg.id) (VM re-init)")
            startAckPoll(
                commandID: msg.commandID!,
                messageID: msg.id,
                targetDisplay: nil,
                expiresAt: nil
            )
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
        surfacedReflectionSubmissionIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Strategy-agent T11: conversation_id + answer-question + feedback

    @AppStorage("evlin.conversation_id") private var conversationIdString: String = ""

    /// Stable per-device conversation token; auto-rotates when blank.
    /// Mirror of SmartModeStore.conversationId so ChatViewModel can stamp it
    /// onto outgoing /parent/chat and /parent/chat/answer-question requests.
    private var conversationId: UUID {
        if let u = UUID(uuidString: conversationIdString) { return u }
        let fresh = UUID()
        conversationIdString = fresh.uuidString
        return fresh
    }

    /// Strategy-agent T11.11 — POST /parent/chat/answer-question and feed
    /// the response back through the existing chat pipeline.
    func sendAnswer(_ body: AnswerQuestionBody) async {
        guard let url = URL(string: "\(apiClient.baseURL)/parent/chat/answer-question") else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
        self.isThinking = true
        defer { self.isThinking = false }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let response = try JSONDecoder().decode(APIClient.ChatResponse.self, from: data)
            await MainActor.run {
                self.processResponse(response, userMessage: "")
            }
        } catch {
            print("answer-question failed: \(error)")
        }
    }

    /// Strategy-agent T11.11 — POST 👍/👎 feedback for an assistant turn.
    func sendFeedback(messageId: String, rating: ChatFeedbackRating) async {
        let (familyID, _) = currentFamilyAndChildIDs()
        guard let fam = familyID else { return }
        try? await FeedbackService(baseURL: apiClient.baseURL).submit(
            familyId: fam,
            conversationId: conversationId,
            messageId: messageId,
            rating: rating
        )
    }

    // MARK: - Send

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Dismiss any stale card / queue from the previous turn. The user
        // typing a new question signals they've moved on; otherwise the
        // old card stays pinned to the bottom and the new user bubble +
        // thinking indicator render ABOVE it, breaking the
        // "newest at the bottom" chat convention. The staged plan_token
        // on the backend expires from ProposalStore naturally (TTL 600s);
        // no explicit cancel needed for this UX fix.
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        currentCard = nil

        messages.append(ChatMessage(role: .parent, content: text, timestamp: Date()))
        inputText = ""
        isThinking = true
        errorMessage = nil

        lastUserMessageForCard = text
        dispatchChat(userMessage: text, forceConfirmations: [])
    }

    func sendQuickPrompt(_ prompt: QuickPrompt) {
        inputText = prompt.text
        sendMessage()
    }

    /// Re-send the parent's most recent user message with `skip_fastpath=true`
    /// so the backend bypasses its deterministic router and routes through
    /// strategy_agent (the LLM path). Wired to the "This isn't what I meant"
    /// button below every confirm card — gives the parent a one-tap escape
    /// when the fastpath interpreted their words wrong.
    ///
    /// Discards the current card / pending plan-arch queue so the next AI
    /// reply replaces them; user sees typing dots immediately so the UI
    /// doesn't feel frozen during the LLM round-trip.
    func reinterpretWithAI() {
        guard let lastUser = messages.last(where: { $0.role == .parent })?.content,
              !lastUser.isEmpty else {
            return
        }

        // Wipe the card surfaces — the new turn will repopulate them.
        // We do NOT remove the user message from history; the LLM benefits
        // from seeing both turns ("user said X, AI's first attempt was a
        // wrong fastpath card, now reinterpret").
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        currentCard = nil
        isThinking = true
        errorMessage = nil
        lastUserMessageForCard = lastUser

        dispatchChat(userMessage: lastUser, forceConfirmations: [], skipFastpath: true)
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
    private func dispatchChat(
        userMessage: String,
        forceConfirmations: [String],
        skipFastpath: Bool = false,
    ) {
        let history: [[String: String]] = messages.suffix(10).map { msg in
            ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                // Fetch both the decoded ChatResponse AND the raw HTTP body so that
                // tryHandlePlanArchCard (plan-arch dual-path) can inspect card_payload
                // without requiring APIClient changes.
                let (resp, rawData, turnID) = try await self.sendChatMessageWithRawData(
                    message: userMessage,
                    childName: self.childName,
                    history: history,
                    forceConfirmations: forceConfirmations,
                    skipFastpath: skipFastpath
                )
                // Source flag for "This isn't what I meant" gating — must
                // be updated BEFORE the response handlers append the
                // pendingPlanArchCard so ChatView's card-render branch
                // observes the correct flag value on the same render pass.
                await MainActor.run {
                    self.lastResponseViaFastpath = resp.viaFastpath ?? false
                }
                // Plan-arch dual-path: if the backend returned a card_payload field
                // (AGENT_PLAN_ARCH=1), surface it via the new renderer path and skip
                // the legacy proposal/action handling. Backwards-compatible: when
                // AGENT_PLAN_ARCH=0, card_payload is absent, and this returns false.
                if await MainActor.run(body: { self.tryHandlePlanArchCard(from: rawData, message: resp.message, debugTurnID: turnID) }) {
                    await MainActor.run { self.isThinking = false }
                    return
                }
                await MainActor.run { self.processResponse(resp, userMessage: userMessage, debugTurnID: turnID) }
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
    private func processResponse(_ resp: APIClient.ChatResponse, userMessage: String, debugTurnID: String? = nil) {
        let bubbleDebugTurnID = Self.bubbleDebugTurnID(debugTurnID)

        // 1. Card rendering
        if let act = resp.action, let cardIDStr = act.card_id, let cardID = CardID(rawValue: cardIDStr) {
            messages.append(ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
            ))
            renderCard(cardID: cardID, action: act)
            isThinking = false
            return
        }

        // 1.5 Plan-arch executed response. The backend can queue multiple
        // child commands from a single parent request, e.g. "lock IG and
        // Venmo". Each command needs its own receipt/ack poll; otherwise the
        // UI only shows the first queued lock.
        if let queuedCommands = resp.queuedCommands, !queuedCommands.isEmpty {
            appendPlanPatchExecutedMessage(
                message: resp.message,
                reasoning: resp.reasoning,
                queuedCommands: queuedCommands,
                debugTurnID: bubbleDebugTurnID
            )
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
                reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
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
            // Pre-flight every proposal: shield_app_legacy with app/category
            // kind needs LocalAliasStore resolution before Confirm.
            for p in resp.proposals ?? [] {
                let targets = Self.extractAliasTargets(from: p)
                for (idx, entry) in targets.enumerated() {
                    guard let (target, kind) = entry else { continue }
                    let aliasResolved = aliasResolvedForLazyTagPreflight(target: target, kind: kind)
                    if !aliasResolved {
                        pendingAliasMisses[Self.aliasMissKey(token: p.token, rowIndex: idx)] = kind
                    }
                }
            }
            var msg = ChatMessage(
                role: .agent, content: resp.message, timestamp: Date(),
                reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
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
            reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
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
        // U1 unlock-disambiguation has its own context shape — parse the
        // shield list out of AnyCodable (recursive — value is [Any] of dicts).
        if cardID == .U1 {
            let token = act.u1_token ?? ""
            let rawList = (act.u1_shield_list?.value as? [Any]) ?? []
            let entries = rawList.enumerated().compactMap { idx, item -> U1ShieldEntry? in
                guard let dict = item as? [String: Any] else { return nil }
                return U1ShieldEntry(
                    index: idx,
                    kind: dict["kind"] as? String ?? "app",
                    displayName: dict["display_name"] as? String ?? "(unknown)",
                    expiresAtISO: dict["expires_at_iso"] as? String,
                    stale: dict["stale"] as? Bool ?? false,
                    // Phase 1b coverage flags — defaulted so legacy U1
                    // payloads (which don't emit these keys) decode as
                    // "no coverage" and the row stays fully tappable.
                    coveredByAll: dict["covered_by_all"] as? Bool ?? false,
                    categoryWarnings: dict["category_warnings"] as? [String] ?? []
                )
            }
            let ctx = CardContext(
                targetDisplay: "",
                childName: self.childName,
                durationMinutes: nil, categoryGuess: nil,
                listSuggestions: [], existingLists: [], blockItems: [],
                childDevices: [], mode: self.protectionMode,
                existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil,
                u1Token: token,
                u1ShieldList: entries
            )
            let handlers = CardHandlers(
                onCancel: { [weak self] in self?.currentCard = nil },
                onU1UnlockSelected: { [weak self] indices in
                    self?.handleU1UnlockSelected(token: token, indices: indices)
                },
                onU1UnlockEverything: { [weak self] in
                    self?.handleU1UnlockEverything(token: token)
                }
            )
            self.currentCard = (cardID, ctx, handlers)
            return
        }

        let context = CardContext(
            targetDisplay: act.target_display ?? "",
            childName: self.childName,
            durationMinutes: act.duration_minutes,
            categoryGuess: act.category_guess,
            listSuggestions: act.list_suggestions ?? [],
            existingLists: [], blockItems: [], childDevices: [],
            mode: self.protectionMode,
            existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil,
            u1Token: nil, u1ShieldList: []
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

    // MARK: - U1 unlock-disambiguation

    enum U1Mode {
        case all
        case selected([Int])
    }

    nonisolated static func buildU1Marker(token: String, mode: U1Mode) -> String? {
        switch mode {
        case .all:
            return "U1:\(token):all"
        case .selected(let indices):
            guard !indices.isEmpty else { return nil }
            let idx = indices.sorted().map(String.init).joined(separator: ",")
            return "U1:\(token):selected:\(idx)"
        }
    }

    func handleU1UnlockSelected(token: String, indices: [Int]) {
        guard let marker = Self.buildU1Marker(token: token, mode: .selected(indices))
        else { return }
        let originalMessage = lastUserMessageForCard
        dispatchChat(userMessage: originalMessage, forceConfirmations: [marker])
        currentCard = nil
    }

    func handleU1UnlockEverything(token: String) {
        let marker = Self.buildU1Marker(token: token, mode: .all)!
        let originalMessage = lastUserMessageForCard
        dispatchChat(userMessage: originalMessage, forceConfirmations: [marker])
        currentCard = nil
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

        case .U1:
            // U1 has no "primary" button — Unlock selected and Unlock
            // everything are wired through onU1UnlockSelected /
            // onU1UnlockEverything in CardHandlers (see CardDispatcher
            // .U1 case + ChatViewModel.handleU1UnlockSelected /
            // handleU1UnlockEverything). This branch only exists to keep
            // the switch exhaustive; primary should never fire on U1.
            currentCard = nil

        case .reflectionReview, .contentGenFailed:
            // Phase 2B placeholders — 2A backend never emits these.
            currentCard = nil
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

    func requestUnlock(_ target: ReceiptUnlockTarget) {
        Task { [weak self] in
            let result = await ActionExecutor.shared.executeReceiptUnlock(target)
            await MainActor.run {
                self?.appendReceiptUnlockResult(result, requestedTarget: target)
            }
        }
    }

    @MainActor
    private func appendReceiptUnlockResult(_ result: AckResult, requestedTarget: ReceiptUnlockTarget) {
        var message = ChatMessage(
            role: .agent,
            content: "Unlock \(requestedTarget.displayName)",
            timestamp: Date()
        )

        switch result {
        case .confirmedExact(let verb, let displayName, let effectiveState):
            message.receiptState = .confirmedExact(verb: verb, displayName: displayName, unlocksAt: nil)
            message.receiptEffectiveState = effectiveState
        case .confirmedFallback(let verb, let displayName, let category, let origRequest, let effectiveState):
            message.receiptState = .confirmedFallback(
                verb: verb,
                displayName: displayName,
                category: category,
                origRequest: origRequest
            )
            message.receiptEffectiveState = effectiveState
        case .pendingConfirmation:
            message.receiptState = .failedOther(reason: "This unlock needs confirmation.")
        case .failed(let failure):
            message.receiptState = receiptState(for: failure)
        }

        messages.append(message)
    }

    private func receiptState(for failure: AckFailure) -> ReceiptState {
        switch failure {
        case .notAuthorized:
            return .failedPermission
        case .listNotFound(let listName):
            return .failedListNotFound(listName: listName)
        case .categoryNotConfigured(let category):
            return .failedCategoryNotConfigured(category: category)
        case .applicationNotConfigured(let reference):
            return .failedAppNotConfigured(appReference: reference)
        case .nothingToUnlock:
            return .failedOther(reason: "Nothing matched to unlock.")
        case .malformed:
            return .failedOther(reason: "The command wasn't well-formed.")
        case .execution(let message):
            return .failedOther(reason: message)
        }
    }

    // MARK: - Ack-status polling (P1-1 fix)

    /// Polls /parent/ack-status for a queued command and mutates the agent
    /// message's receiptState when the child acks. Times out at 30 s.
    private func startAckPoll(commandID: UUID, messageID: UUID, targetDisplay: String?, expiresAt: Date?) {
        print("[AckPoll] start cmd=\(commandID) msg=\(messageID) deadline=90s")
        let task = Task { [weak self] in
            // 90s deadline. Real two-device kids ack within seconds; if
            // we've waited 90s the device almost certainly isn't online.
            // Was 24h, which left an indefinite spinner whenever the
            // parent stayed in P mode (single-device test) or the kid
            // device was offline. Honest "kid hasn't responded" state
            // beats infinite ProgressView — the command itself remains
            // queued server-side regardless of when we stop polling.
            let deadline = Date().addingTimeInterval(90)
            var tickCount = 0
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { print("[AckPoll] self gone cmd=\(commandID)"); return }
                tickCount += 1
                let resp: AckStatusResponse
                do {
                    resp = try await self.apiClient.fetchRichAckStatus(commandID: commandID)
                } catch {
                    print("[AckPoll] tick=\(tickCount) cmd=\(commandID) fetch error: \(error)")
                    continue
                }
                print("[AckPoll] tick=\(tickCount) cmd=\(commandID) status=\(resp.status)")

                let done = await MainActor.run { () -> Bool in
                    switch resp.status {
                    case "pending", "queued", "in_flight":
                        return false
                    case "confirmed", "confirmed_exact":
                        let verb = AckVerb(rawValue: resp.verb ?? "shield") ?? .shield
                        let name = resp.displayName ?? targetDisplay ?? ""
                        // Prefer kid-reported expiry over parent-estimated. The
                        // legacy-exec path through /parent/agent/exec sometimes
                        // returns legacy_action with duration_minutes=nil even
                        // when the shield was timed (round-trip loss in
                        // staging), which made every confirmed receipt say
                        // "Until you unlock". Kid's effectiveState carries the
                        // actually-applied expiresAtISO; use that when present.
                        let actualUnlocksAt = resp.effectiveState
                            .flatMap { $0.shieldsCovering.first?.expiresAtISO }
                            .flatMap { ISO8601DateFormatter().date(from: $0) }
                            ?? expiresAt
                        self.applyReceipt(
                            .confirmedExact(verb: verb, displayName: name, unlocksAt: actualUnlocksAt),
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
                        case "application_not_configured":
                            state = .failedAppNotConfigured(
                                appReference: (detail["app_reference"]?.value as? String) ?? "(unknown)"
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
            // Deadline hit without a terminal status. Show
            // `.kidNotResponding` instead of leaving the spinner up —
            // the receipt is honest (kid hasn't acked yet) without
            // claiming the command itself failed. Applies whether the
            // parent stayed in P mode (single-device dev) or the kid
            // device is genuinely offline; the server-queued command
            // still executes once the kid comes back.
            print("[AckPoll] deadline hit cmd=\(commandID) ticks=\(tickCount) cancelled=\(Task.isCancelled) — applying .kidNotResponding")
            await MainActor.run {
                self?.applyReceipt(.kidNotResponding, effective: nil, messageID: messageID)
                print("[AckPoll] applyReceipt done cmd=\(commandID)")
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
            existingMode: ctx["existing_mode"],
            u1Token: nil, u1ShieldList: []
        )
        let fakeAction = APIClient.ChatActionResponse(
            type: "shield", command_id: nil, tier: nil,
            target_display: ctx["target_display"],
            duration_minutes: Int(ctx["requested_duration_minutes"] ?? ""),
            confirmation_required: true,
            card_id: cardID.rawValue,
            confirmation_reason: nil, list_suggestions: nil, category_guess: nil,
            u1_token: nil, u1_shield_list: nil
        )
        let handlers = CardHandlers(
            onPrimary: { [weak self] in self?.handleCardPrimary(cardID: cardID, action: fakeAction) },
            onSecondary: { [weak self] in self?.handleCardSecondary(cardID: cardID, action: fakeAction) },
            onCancel: { [weak self] in self?.currentCard = nil }
        )
        self.currentCard = (cardID, cardCtx, handlers)
    }

    // MARK: - Fetch video recommendation

    // MARK: - Lazy tagging

    /// Pure parser: pull `(target, kind)` out of a ProposalDTO if it's a
    /// `shield_app_legacy` call with a kind that needs alias resolution.
    /// `nonisolated` so XCTest can call without @MainActor isolation drama.
    nonisolated static func extractAliasTarget(
        from proposal: ProposalDTO
    ) -> (target: String, kind: AliasKind)? {
        // shield_app_legacy and unshield_app_legacy both stage the same
        // {target, target_kind} args shape — pre-flight runs identically.
        guard proposal.tool == "shield_app_legacy"
            || proposal.tool == "unshield_app_legacy"
        else { return nil }
        guard let target = proposal.args["target"]?.value as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let rawKind = proposal.args["target_kind"]?.value as? String else { return nil }
        switch rawKind {
        case "app": return (target, .app)
        case "category": return (target, .category)
        default: return nil
        }
    }

    /// Multi-row variant. Returns `[Optional]` with same length as rows;
    /// nil at index i means row i isn't an alias-eligible target (kind
    /// outside {app, category}). Empty list when proposal has no rows
    /// AND no top-level target/kind args.
    nonisolated static func extractAliasTargets(
        from proposal: ProposalDTO
    ) -> [(target: String, kind: AliasKind)?] {
        guard proposal.tool == "shield_app_legacy"
            || proposal.tool == "unshield_app_legacy"
        else { return [] }

        // New shape: args.rows is an array of {target, target_kind, minutes}
        func parseRow(_ row: [String: Any]) -> (target: String, kind: AliasKind)? {
            guard let target = row["target"] as? String,
                  !target.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            guard let rawKind = row["target_kind"] as? String else { return nil }
            switch rawKind {
            case "app": return (target, .app)
            case "category": return (target, .category)
            default: return nil
            }
        }

        let rowsValue = proposal.args["rows"]?.value
        if let rows = rowsValue as? [[String: AnyCodable]] {
            return rows.map { row in
                parseRow(row.mapValues { $0.value })
            }
        }
        if let rows = rowsValue as? [[String: Any]] {
            return rows.map(parseRow)
        }
        if let rowsAny = rowsValue as? [Any] {
            return rowsAny.map { rowAny -> (target: String, kind: AliasKind)? in
                if let row = rowAny as? [String: Any] {
                    return parseRow(row)
                }
                if let row = rowAny as? [String: AnyCodable] {
                    return parseRow(row.mapValues { $0.value })
                }
                return nil
            }
        }

        // Legacy shape: {target, target_kind} at top level. Return as 1-row list.
        if let single = extractAliasTarget(from: proposal) {
            return [single]
        }
        return []
    }

    nonisolated static func aliasMissKey(token: String, rowIndex: Int) -> String {
        "\(token)#\(rowIndex)"
    }

    private func aliasResolvedForLazyTagPreflight(target: String, kind: AliasKind) -> Bool {
        switch kind {
        case .app:
            let activeTokens = ScreenTimeManager.shared.selectedApps.applicationTokens
            return LocalAliasStore.shared.activeApplicationToken(
                forLookupKey: target,
                activeTokens: activeTokens
            ) != nil
        case .category:
            return LocalAliasStore.shared.categoryToken(forName: target) != nil
        }
    }

    /// True if the proposal currently has no alias miss outstanding on
    /// any of its rows.
    func aliasHit(for proposal: ProposalDTO) -> Bool {
        let targets = Self.extractAliasTargets(from: proposal)
        for idx in 0..<targets.count {
            let key = Self.aliasMissKey(token: proposal.token, rowIndex: idx)
            if pendingAliasMisses[key] != nil { return false }
        }
        return true
    }

    /// Per-row miss targets for ProposalCard. Index-aligned with the
    /// proposal's rows. nil at i means row i has no outstanding miss.
    func rowAliasMissTargets(for proposal: ProposalDTO) -> [String?] {
        let targets = Self.extractAliasTargets(from: proposal)
        return targets.enumerated().map { idx, entry in
            let key = Self.aliasMissKey(token: proposal.token, rowIndex: idx)
            // pendingAliasMisses is [String: AliasKind] — presence means MISS.
            if pendingAliasMisses[key] != nil {
                return entry?.target
            }
            return nil
        }
    }

    @MainActor
    func beginLazyTag(for proposal: ProposalDTO, rowIndex: Int) {
        let targets = Self.extractAliasTargets(from: proposal)
        guard rowIndex < targets.count, let (target, kind) = targets[rowIndex] else { return }
        activeLazyTagRequest = LazyTagRequest(
            proposalToken: proposal.token,
            rowIndex: rowIndex,
            target: target,
            kind: kind
        )
    }

    @MainActor
    func handleTagSelection(token: Any, request: LazyTagRequest) {
        let result = LazyTagPersistence.persistAlias(
            token: token,
            kind: request.kind,
            target: request.target
        )
        switch result {
        case .success:
            let isPlanArchLazyTag = planArchLazyTagRequestIDs.remove(request.id) != nil
            // Clear THIS row's miss + sweep any other pending per-row misses
            // for the same (target, kind) — handles multi-card and multi-row
            // chats like "lock IG and TikTok" where two rows reference Instagram.
            let key = Self.aliasMissKey(
                token: request.proposalToken, rowIndex: request.rowIndex
            )
            pendingAliasMisses.removeValue(forKey: key)
            sweepResolvedMisses(target: request.target, kind: request.kind)
            activeLazyTagRequest = nil
            if isPlanArchLazyTag {
                resumePlanArchAfterLazyTag(request)
            }
        case .failure(let err):
            errorMessage = "Couldn't save the tag: \(err)"
            // Leave activeLazyTagRequest intact so user can retry.
        }
    }

    @MainActor
    private func resumePlanArchAfterLazyTag(_ request: LazyTagRequest) {
        guard !apiClient.baseURL.isEmpty, let baseURL = URL(string: apiClient.baseURL) else {
            messages.append(ChatMessage(role: .agent, content: "No backend URL configured.", timestamp: Date()))
            return
        }
        let ids = currentFamilyAndChildIDs()
        let aliasState = currentClientAliasStateJSON()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await PlanPatchClient(baseURL: baseURL).submitPatch(
                planToken: request.proposalToken,
                stepIndex: request.rowIndex,
                patch: ["target": ["alias_confirmed": true]],
                cancel: false,
                clientAliasState: aliasState,
                familyID: ids.familyID,
                childDeviceID: ids.childDeviceID
            )
            await MainActor.run {
                switch outcome {
                case .executed(let message, let reasoning, let queuedCommands):
                    self.appendPlanPatchExecutedMessage(message: message, reasoning: reasoning, queuedCommands: queuedCommands)
                case .followUpCard(let next):
                    self.pendingPlanArchCard = next
                    let body = next.body.map { "\(next.title)\n\n\($0)" } ?? next.title
                    self.messages.append(ChatMessage(role: .agent, content: body, timestamp: Date()))
                case .rejected(let message), .expired(let message):
                    self.messages.append(ChatMessage(role: .agent, content: message, timestamp: Date()))
                case .error(let err):
                    self.messages.append(ChatMessage(role: .agent, content: "Error: \(err.localizedDescription)", timestamp: Date()))
                }
            }
        }
    }

    @MainActor
    func cancelLazyTag() {
        if let req = activeLazyTagRequest {
            planArchLazyTagRequestIDs.remove(req.id)
        }
        activeLazyTagRequest = nil
    }

    /// Removes any `pendingAliasMisses` entries whose proposal-row's
    /// (target, kind) match. Called after a successful tag — even if the
    /// chat had multiple cards/rows referencing the same name, they all clear.
    /// Keys in `pendingAliasMisses` are `"\(proposalToken)#\(rowIndex)"`.
    @MainActor
    private func sweepResolvedMisses(target: String, kind: AliasKind) {
        let normalizedTarget = target.lowercased()
        for key in Array(pendingAliasMisses.keys) {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let rowIndex = Int(parts[1])
            else { continue }
            let token = String(parts[0])
            guard let p = findProposal(byToken: token) else { continue }
            let targets = Self.extractAliasTargets(from: p)
            guard rowIndex < targets.count,
                  let (t, k) = targets[rowIndex]
            else { continue }
            if k == kind && t.lowercased() == normalizedTarget {
                pendingAliasMisses.removeValue(forKey: key)
            }
        }
    }

    private func findProposal(byToken token: String) -> ProposalDTO? {
        for msg in messages.reversed() {
            if let proposals = msg.proposals,
               let found = proposals.first(where: { $0.token == token }) {
                return found
            }
        }
        return nil
    }

    // MARK: - Agent envelope handlers (Phase E)

    /// Parent tapped Confirm on a ProposalCard. POST /parent/agent/exec,
    /// then move the proposal to the receipts list on the same agent message
    /// so the card flips into a ReceiptBubble in place.
    @MainActor
    func confirmProposal(_ p: ProposalDTO) async {
        // Hard guard: refuse to dispatch if any per-row alias miss is
        // outstanding for this proposal. UI also disables Confirm; this is
        // defense in depth.
        let targets = Self.extractAliasTargets(from: p)
        for (idx, _) in targets.enumerated() {
            let key = Self.aliasMissKey(token: p.token, rowIndex: idx)
            if pendingAliasMisses[key] != nil {
                errorMessage = "Tap \"Tag\" first so I know which app you mean."
                return
            }
        }
        self.isThinking = true
        defer { self.isThinking = false }
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            let result = try await client.executeProposal(token: p.token)
            switch result {
            case .receipt(let receipt):
                if let i = messages.lastIndex(where: { $0.role == .agent }) {
                    var msg = messages[i]
                    msg.proposals?.removeAll(where: { $0.token == p.token })
                    msg.receipts = (msg.receipts ?? []) + [receipt]
                    messages[i] = msg
                }
            case .legacyAction(let action, let message, let reasoning):
                // Remove the proposal from the previous agent bubble so the
                // ProposalCard disappears. We do NOT thread the legacy action
                // through ChatMessage.init(action:) — that param is for the
                // old ChatAction enum and isn't read by ChatView anyway.
                if let i = messages.lastIndex(where: { $0.role == .agent }) {
                    var msg = messages[i]
                    msg.proposals?.removeAll(where: { $0.token == p.token })
                    messages[i] = msg
                }
                // Mirror processResponse's command_id branch: append a fresh
                // agent bubble carrying message + reasoning, then if the
                // dispatcher gave us a command_id, attach pending state and
                // start ack-poll. The bubble's commandID is what drives
                // ChatView's ReceiptCard rendering + ack updates.
                if let act = action, let cid = act.command_id {
                    var msg = ChatMessage(
                        role: .agent,
                        content: message ?? "",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil    // legacy enum field, intentionally nil
                    )
                    msg.commandID = cid
                    msg.receiptState = .pending
                    messages.append(msg)
                    startAckPoll(
                        commandID: cid,
                        messageID: msg.id,
                        targetDisplay: act.target_display,
                        expiresAt: act.duration_minutes.map {
                            Date().addingTimeInterval(TimeInterval($0 * 60))
                        }
                    )
                } else if let act = action, act.card_id != nil {
                    // v1 doesn't render dispatcher-staged secondary cards
                    // (D1 duration picker, A1 destructive confirm) on the
                    // legacy-exec path. Surface a clear message instead of
                    // silently dropping. This is rare for confirmed shields
                    // since duration/destructive confirms happen BEFORE the
                    // proposal stage.
                    let bubble = ChatMessage(
                        role: .agent,
                        content: message ?? "(unsupported response)",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil
                    )
                    messages.append(bubble)
                    errorMessage = "Couldn't show the next step. Try again."
                } else {
                    // No command_id, no card — text-only response. Display
                    // it as plain agent message.
                    let bubble = ChatMessage(
                        role: .agent,
                        content: message ?? "",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil
                    )
                    messages.append(bubble)
                }
            case .legacyActions(let results, _, let reasoning):
                // Remove the proposal from the previous agent bubble (it's been
                // confirmed; ProposalCard should disappear).
                if let i = messages.lastIndex(where: { $0.role == .agent }) {
                    var msg = messages[i]
                    msg.proposals?.removeAll(where: { $0.token == p.token })
                    messages[i] = msg
                }
                // For each sub-action with a command_id: append a fresh agent
                // bubble + start its own ack-poll. Receipts update independently.
                for result in results {
                    guard let act = result.action, let cid = act.command_id else {
                        // No command_id (text-only result) — append as plain bubble.
                        let bubble = ChatMessage(
                            role: .agent,
                            content: result.message ?? "",
                            timestamp: Date(),
                            reasoning: reasoning,
                            action: nil
                        )
                        messages.append(bubble)
                        continue
                    }
                    var msg = ChatMessage(
                        role: .agent,
                        content: result.message ?? "",
                        timestamp: Date(),
                        reasoning: reasoning,
                        action: nil
                    )
                    msg.commandID = cid
                    msg.receiptState = .pending
                    messages.append(msg)
                    startAckPoll(
                        commandID: cid,
                        messageID: msg.id,
                        targetDisplay: act.target_display,
                        expiresAt: act.duration_minutes.map {
                            Date().addingTimeInterval(TimeInterval($0 * 60))
                        }
                    )
                }
            }
            // Tell any active BigKidStatePoller to refresh immediately —
            // this is what makes a parent-confirmed reflection / task /
            // bypass appear on the kid side without waiting for the poll
            // cycle. Same-device dev (parent + kid in one app) was the
            // motivating case; on separate devices the kid still picks
            // it up via the next poll.
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - BigKid reflection submission (poll /child/state → chat bubble)

    private func rebuildSurfacedReflectionSubmissionIndex() {
        surfacedReflectionSubmissionIDs = Set(
            messages.compactMap { msg in
                // Only `.open` entries should suppress re-surfacing.
                // Once parent acts (approved or sent back) the card is
                // resolved, but a NEW kid submission for the same rid
                // is still worth re-surfacing — same predicate as
                // before just expressed via the tri-state.
                guard let r = msg.reflectionSubmissionReview, r.status == .open else { return nil }
                return r.reflectionId
            }
        )
    }

    func startReflectionSubmissionPolling() {
        reflectionSubmissionPoll?.cancel()
        rebuildSurfacedReflectionSubmissionIndex()
        reflectionSubmissionPoll = Timer.publish(every: 28, tolerance: 8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.tickReflectionSubmissionPoll() }
            }
    }

    func stopReflectionSubmissionPolling() {
        reflectionSubmissionPoll?.cancel()
        reflectionSubmissionPoll = nil
    }

    // MARK: - Reflection event polling (Phase 2B)
    // Polls GET /parent/reflection/pending-events every 30s while ChatView is
    // visible and no card is already pending. Backend returns an empty list when
    // the AGENT_PLAN_ARCH_REFLECTION flag is off, so this is safe to run always.

    private var reflectionEventPoll: AnyCancellable?

    func startReflectionEventPolling() {
        reflectionEventPoll?.cancel()
        reflectionEventPoll = Timer.publish(every: 30, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.tickReflectionEventPoll() }
            }
        // Fire once immediately
        Task { await tickReflectionEventPoll() }
    }

    func stopReflectionEventPolling() {
        reflectionEventPoll?.cancel()
        reflectionEventPoll = nil
    }

    func tickReflectionEventPoll() async {
        // Don't interrupt a card already in-flight
        guard await MainActor.run(body: { self.pendingPlanArchCard == nil }) else { return }

        let rawBase = await MainActor.run { self.apiClient.baseURL }
        guard !rawBase.isEmpty, let _ = URL(string: rawBase) else { return }

        let url = URL(string: "\(rawBase)/parent/reflection/pending-events")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            // Backend returns a JSON array of card_payload objects.
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first,
                  let cardData = try? JSONSerialization.data(withJSONObject: first),
                  let card = try? JSONDecoder().decode(PlanArchCardPayload.self, from: cardData)
            else { return }

            await MainActor.run {
                guard self.pendingPlanArchCard == nil else { return }
                self.pendingPlanArchCard = card
                let composed: String
                if let body = card.body, !body.isEmpty {
                    composed = "\(card.title)\n\n\(body)"
                } else {
                    composed = card.title
                }
                self.messages.append(ChatMessage(role: .agent, content: composed, timestamp: Date()))
            }
        } catch {
            print("[ReflectionEventPoll] fetch error: \(error)")
        }
    }

    func tickReflectionSubmissionPoll() async {
        guard let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let childUUID = UUID(uuidString: raw),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        do {
            let state = try await apiClient.fetchChildStateForParentReview(childDeviceId: childUUID)
            surfaceReflectionSubmissionBubbleIfNeeded(state: state)
        } catch {}
    }

    /// Approve from `ReflectionSubmissionReviewCard` — same POST as `ParentBigKidDebugSheet`.
    func approveReflectionSubmissionFromChat(
        messageId: UUID,
        reflectionId: UUID,
        parentNoteTrimmed: String
    ) async {
        errorMessage = nil
        let noteToSend = parentNoteTrimmed.isEmpty
            ? ReflectionParentNoteFallback.thanksHonest
            : parentNoteTrimmed
        self.isThinking = true
        defer { self.isThinking = false }
        do {
            try await apiClient.approveChildReflectionSubmission(
                reflectionId: reflectionId,
                parentNote: noteToSend
            )
            if let idx = messages.firstIndex(where: { $0.id == messageId }) {
                var m = messages[idx]
                if var r = m.reflectionSubmissionReview {
                    r.status = .approved
                    m.reflectionSubmissionReview = r
                    messages[idx] = m
                }
            }
            let noteLine = "\n\nYour note to them: “\(noteToSend)”"
            messages.append(ChatMessage(
                role: .agent,
                content:
                    "You approved \(childName)’s reflection. They’ll move forward on their device with your message.\(noteLine)",
                timestamp: Date()
            ))
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            messages.append(ChatMessage(
                role: .agent,
                content:
                    "I couldn’t approve the reflection right now — \(error.localizedDescription). Tap Approve to try again.",
                timestamp: Date()
            ))
        }
    }

    /// "Write again" from `ReflectionSubmissionReviewCard` — same
    /// backend endpoint as the Step-3 Request-Redo button. If the
    /// parent typed something in the "Message for {child}" editor,
    /// that text goes to the kid verbatim; only when it's empty do
    /// we substitute the default `redoTakeAnotherLook` coaching
    /// string. On success the message payload flips to `.sentBack`
    /// (red header pill); on failure we surface an error so the
    /// parent can retry.
    func requestRedoReflectionFromChat(
        messageId: UUID,
        reflectionId: UUID,
        parentNoteTrimmed: String
    ) async {
        errorMessage = nil
        let note = parentNoteTrimmed.isEmpty
            ? ReflectionParentNoteFallback.redoTakeAnotherLook
            : parentNoteTrimmed
        self.isThinking = true
        defer { self.isThinking = false }
        do {
            try await apiClient.requestRedoChildReflection(
                reflectionId: reflectionId,
                redoNote: note
            )
            if let idx = messages.firstIndex(where: { $0.id == messageId }) {
                var m = messages[idx]
                if var r = m.reflectionSubmissionReview {
                    r.status = .sentBack
                    m.reflectionSubmissionReview = r
                    messages[idx] = m
                }
            }
            messages.append(ChatMessage(
                role: .agent,
                content:
                    "Sent back to \(childName) — they'll rework the essay. Your note: “\(note)”",
                timestamp: Date()
            ))
            NotificationCenter.default.post(name: .bigKidStateInvalidated, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            messages.append(ChatMessage(
                role: .agent,
                content:
                    "I couldn’t send the reflection back right now — \(error.localizedDescription). Tap Write again to retry.",
                timestamp: Date()
            ))
        }
    }

    private func surfaceReflectionSubmissionBubbleIfNeeded(state: ChildStateResponse) {
        guard let req = state.reflectionRequest,
              req.status == .submitted,
              let essay = req.essayText,
              !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        guard !surfacedReflectionSubmissionIDs.contains(req.id) else { return }

        let prompt = req.writingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        surfacedReflectionSubmissionIDs.insert(req.id)

        let preamble = """
        \(childName) has finished the reflection exercise and submitted an essay below.

        **Essay prompt** and **their writing** follow. Review them, optionally add a short closing note for them on-device, then tap **Approve**.
        """

        var msg = ChatMessage(role: .agent, content: preamble, timestamp: Date())
        msg.reflectionSubmissionReview = ReflectionSubmissionReviewPayload(
            reflectionId: req.id,
            writingPrompt: prompt,
            essayText: essay,
            status: .open,
            submittedAt: req.submittedAt,
            topicLabel: req.topicLabel,
            stepsCompleted: req.stepsCompleted
        )
        messages.append(msg)
    }

    /// Parent tapped Skip — drop the proposal from the most recent agent message.
    @MainActor
    func skipProposal(_ p: ProposalDTO) {
        // Clear any outstanding alias misses on every row — Skip means
        // "don't do this", which doesn't need a tag. Keeps state tidy.
        let prefix = "\(p.token)#"
        for key in Array(pendingAliasMisses.keys) where key.hasPrefix(prefix) {
            pendingAliasMisses.removeValue(forKey: key)
        }
        if let i = messages.lastIndex(where: { $0.role == .agent }) {
            var msg = messages[i]
            msg.proposals?.removeAll(where: { $0.token == p.token })
            messages[i] = msg
        }
    }

    /// Parent tapped Undo on a ReceiptBubble. POST the revert and append a
    /// subtle confirmation bubble. Errors flow into errorMessage.
    ///
    /// On success, also nulls the matching `undoToken` on every receipt
    /// across all messages so the bubble doesn't re-render its countdown
    /// button when the chat view rebuilds (tab switch, scroll-into-view).
    @MainActor
    func undoReceipt(token: String) async {
        self.isThinking = true
        defer { self.isThinking = false }
        let client = AgentClient(baseURL: apiClient.baseURL)
        do {
            _ = try await client.revertAction(actionID: token)
            // Persist the undone state by clearing the token on the original
            // receipt — survives view rebuilds AND messages-to-UserDefaults.
            for i in messages.indices {
                guard var rs = messages[i].receipts else { continue }
                var changed = false
                for j in rs.indices where rs[j].undoToken == token {
                    rs[j].undoToken = nil
                    changed = true
                }
                if changed { messages[i].receipts = rs }
            }
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

    /// Mirrors APIClient.sendChatMessage but returns the raw HTTP Data alongside
    /// the decoded ChatResponse. Used by dispatchChat so tryHandlePlanArchCard
    /// can inspect card_payload (a plan-arch-only field not in ChatResponse).
    /// Inherits the same retry / timeout semantics as APIClient.
    private func sendChatMessageWithRawData(
        message: String,
        childName: String,
        history: [[String: String]],
        forceConfirmations: [String],
        skipFastpath: Bool = false
    ) async throws -> (APIClient.ChatResponse, Data, String?) {
        let familyID = UserDefaults.standard.string(forKey: "evlin.familyID")
        let bigKidChildID = UserDefaults.standard.string(forKey: "evlin.childDeviceID")

        let bodyObj = APIClient.ChatRequest(
            message: message,
            child_name: childName,
            history: history,
            family_id: familyID,
            force_confirmations: forceConfirmations,
            child_device_id: (bigKidChildID?.isEmpty == false) ? bigKidChildID : nil,
            client_alias_state: currentClientAliasStateCodable(),
            skip_fastpath: skipFastpath
        )
        let encodedBody = try JSONEncoder().encode(bodyObj)

        var lastStatus = 0
        for attempt in 0..<3 {
            let url = URL(string: "\(apiClient.baseURL)/parent/chat")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = encodedBody

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                lastStatus = http?.statusCode ?? 0

                if lastStatus == 200 {
                    let decoded = try JSONDecoder().decode(APIClient.ChatResponse.self, from: data)
                    let turnID = http?.value(forHTTPHeaderField: "X-Brain-Turn-Id")
                    return (decoded, data, turnID)
                }
                if (lastStatus == 500 || lastStatus == 503), attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
                    continue
                }
                throw APIError.serverError(lastStatus)
            } catch let err as APIError {
                throw err
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
                throw error
            }
        }
        throw APIError.serverError(lastStatus)
    }

    /// Called by the chat response handler with the raw HTTP body Data.
    /// Returns true if a PlanArchCardPayload was detected and stashed in
    /// pendingPlanArchCard (caller should skip legacy proposal/action
    /// branches in that case). Backwards-compatible: legacy responses
    /// have no card_payload and this returns false.
    ///
    /// ALSO appends a chat bubble with the card's title (+ body) so the
    /// parent sees a normal agent reply in the message list while the
    /// PlanArchCardView renders below for interaction.
    func tryHandlePlanArchCard(from data: Data, message: String? = nil, debugTurnID: String? = nil) -> Bool {
        let cards = PlanArchCardPayload.decodeAllFromChatResponseData(data)
        guard !cards.isEmpty else { return false }

        // Replace the queue with this turn's cards. (Don't append — if a
        // prior turn had unanswered cards, this turn's set supersedes.)
        self.pendingPlanArchCardQueue = cards
        self.pendingPlanArchCard = cards.first

        // Append a text bubble ONLY when the backend included a meaningful
        // message (strategy_agent's reasoning_summary). Fast-path responses
        // pass an empty message so the card alone speaks for itself with no
        // redundant chatter above it.
        let trimmedMessage = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            self.messages.append(ChatMessage(
                role: .agent,
                content: trimmedMessage,
                timestamp: Date(),
                debugTurnID: Self.bubbleDebugTurnID(debugTurnID)
            ))
        }
        return true
    }

    private static func bubbleDebugTurnID(_ debugTurnID: String?) -> String? {
        #if DEBUG
        return debugTurnID
        #else
        return nil
        #endif
    }

    /// Plan-arch card option tapped. Switches on payload.source to route:
    ///   .plan  → POST /parent/chat/plan-patch (submitPlanArchPatch)
    ///   .event → handleEventCardStub (2B placeholder)
    ///   .query → handleQueryCardStub (2D placeholder)
    func handlePlanArchOption(_ opt: PlanArchCardOption) {
        guard let card = self.pendingPlanArchCard else { return }
        switch card.source {
        case .plan:
            submitPlanArchPatch(card: card, option: opt)
        case .event:
            handleEventCardStub(card: card, option: opt)
        case .query:
            handleQueryCardStub(card: card, option: opt)
        }
    }

    /// Extracted from the original handlePlanArchOption body (no behaviour change).
    /// Handles cancel + plan-patch POST for .plan source cards.
    private func submitPlanArchPatch(card: PlanArchCardPayload, option opt: PlanArchCardOption) {
        self.advancePlanArchCardQueue()

        if opt.cancelsPlan {
            self.messages.append(ChatMessage(role: .agent, content: "Cancelled.", timestamp: Date()))
            return
        }

        // Build the API base URL. APIClient.baseURL is a non-optional
        // String like "https://evlin-backend.onrender.com/api/v1".
        // PlanPatchClient appends "/parent/chat/plan-patch" itself.
        let rawBase = self.apiClient.baseURL
        guard !rawBase.isEmpty, let trimmed = URL(string: rawBase) else {
            self.messages.append(ChatMessage(role: .agent, content: "No backend URL configured.", timestamp: Date()))
            return
        }

        // Convert PlanArchAnyCodable patch into a plain [String: Any] dict
        // suitable for JSONSerialization in PlanPatchClient.
        let patchDict: [String: Any] = opt.patch.mapValues { $0.value }

        // Show the thinking indicator while plan-patch is in flight. Without
        // this the chat is blank between "user tapped Confirm" and the
        // executor's response — which on a real Gemini-backed reflection
        // executor is 5-15 seconds and feels like the app froze.
        self.isThinking = true

        Task { [weak self] in
            guard let self = self else { return }
            let client = PlanPatchClient(baseURL: trimmed)
            let ids = await MainActor.run { self.currentFamilyAndChildIDs() }
            let aliasState = await MainActor.run { self.currentClientAliasStateJSON() }
            let outcome = await client.submitPatch(
                planToken: card.planToken,
                stepIndex: card.stepIndex,
                patch: patchDict,
                cancel: false,
                clientAliasState: aliasState,
                familyID: ids.familyID,
                childDeviceID: ids.childDeviceID
            )
            await MainActor.run {
                self.isThinking = false
                switch outcome {
                case .executed(let message, let reasoning, let queuedCommands):
                    self.appendPlanPatchExecutedMessage(message: message, reasoning: reasoning, queuedCommands: queuedCommands)
                case .followUpCard(let next):
                    self.pendingPlanArchCard = next
                    let body = next.body.map { "\(next.title)\n\n\($0)" } ?? next.title
                    self.messages.append(ChatMessage(role: .agent, content: body, timestamp: Date()))
                case .rejected(let message), .expired(let message):
                    self.messages.append(ChatMessage(role: .agent, content: message, timestamp: Date()))
                case .error(let err):
                    self.messages.append(ChatMessage(role: .agent, content: "Error: \(err.localizedDescription)", timestamp: Date()))
                }
            }
        }
    }

    private func handleEventCardStub(card: PlanArchCardPayload, option: PlanArchCardOption) {
        // 2A stub — event family is not yet emitted by backend; populated
        // in 2B alongside the reflection submission review polling change.
        Task { @MainActor in
            self.errorMessage = "Event-card actions arrive in Phase 2B."
            self.advancePlanArchCardQueue()
        }
    }

    private func handleQueryCardStub(
        card: PlanArchCardPayload, option: PlanArchCardOption
    ) {
        Task { @MainActor in
            // Query result rows prefill the next chat utterance — they
            // must NOT mutate state (spec §1 invariant 4).
            if !option.label.isEmpty {
                self.inputText = option.label
            }
            self.advancePlanArchCardQueue()
        }
    }

    /// Pop the front of the plan-arch card queue and bring the next card
    /// (if any) into view. Used after the user acts on / dismisses a card.
    @MainActor
    func advancePlanArchCardQueue() {
        if !pendingPlanArchCardQueue.isEmpty {
            pendingPlanArchCardQueue.removeFirst()
        }
        pendingPlanArchCard = pendingPlanArchCardQueue.first
    }

    @MainActor
    private func appendPlanPatchExecutedMessage(
        message: String,
        reasoning: String?,
        queuedCommands: [PlanPatchQueuedCommand],
        debugTurnID: String? = nil
    ) {
        guard !queuedCommands.isEmpty else {
            messages.append(ChatMessage(role: .agent, content: message, timestamp: Date(), reasoning: reasoning, debugTurnID: debugTurnID))
            return
        }

        for (index, command) in queuedCommands.enumerated() {
            let content = queuedCommands.count == 1
                ? message
                : Self.queuedCommandMessage(command)
            var msg = ChatMessage(
                role: .agent,
                content: content,
                timestamp: Date(),
                reasoning: index == 0 ? reasoning : nil,
                debugTurnID: debugTurnID
            )
            msg.commandID = command.commandID
            msg.receiptState = .pending
            messages.append(msg)
            startAckPoll(
                commandID: command.commandID,
                messageID: msg.id,
                targetDisplay: command.targetDisplay,
                expiresAt: command.durationMinutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
            )
        }
    }

    private static func queuedCommandMessage(_ command: PlanPatchQueuedCommand) -> String {
        let target = command.targetDisplay ?? "target"
        switch command.action?.lowercased() {
        case "shield":
            if let minutes = command.durationMinutes {
                return "Shield \(target) for \(minutes) min"
            }
            return "Shield \(target)"
        case "unshield":
            return "Unshield \(target)"
        case "block":
            return "Block \(target)"
        case "unblock":
            return "Unblock \(target)"
        default:
            return target
        }
    }

    /// Plan-arch lazy_tag entry point. Opens the existing production
    /// FamilyActivityPicker-backed tag sheet. After selection,
    /// `handleTagSelection` saves the local alias and resumes the staged plan
    /// via `/parent/chat/plan-patch`.
    func handlePlanArchLazyTag(for card: PlanArchCardPayload) {
        self.advancePlanArchCardQueue()
        let targetName = (card.detail["target_name"]?.value as? String) ?? "the app"
        let rawKind = (card.detail["target_kind"]?.value as? String) ?? "app"
        let kind: AliasKind = rawKind == "category" ? .category : .app
        let request = LazyTagRequest(
            proposalToken: card.planToken,
            rowIndex: card.stepIndex,
            target: targetName,
            kind: kind
        )
        planArchLazyTagRequestIDs.insert(request.id)
        activeLazyTagRequest = request
    }

}

// MARK: - Task 25: Plan-arch handler factory

extension ChatViewModel {
    /// Build a CardHandlers wired to the existing plan-patch flow.
    /// Each handler synthesises the matching PlanArchCardOption and
    /// forwards through `handlePlanArchOption(_:)`. This keeps the
    /// patch-endpoint contract identical to Phase 1 while the adapter
    /// renders polished UI.
    func makePlanArchHandlers(for card: PlanArchCardPayload) -> CardHandlers {
        var handlers = CardHandlers()

        // D1 / MissingInfoCard primary tap → user picked a duration.
        // Backend wire format: {"duration": {"kind": "minutes", "value": N}}
        // or {"duration": {"kind": "permanent"}} — NOT "duration_minutes"/"duration_kind".
        handlers.onDurationPicked = { [weak self] minutes in
            guard let self else { return }
            let durationDict: [String: Any] = minutes.map {
                ["kind": "minutes", "value": $0] as [String: Any]
            } ?? ["kind": "permanent"]
            let opt = PlanArchCardOption.synthesise(
                fromCard: card, patch: ["duration": durationDict]
            )
            self.handlePlanArchOption(opt)
        }

        // U1 / unlock picker — strategy_agent's phone.unlock_picker stages
        // an ActionPlan and expects a plan-patch back, not a chat re-dispatch
        // with a U1Marker (that path was for legacy plan_arch and reads from
        // a different ProposalStore). Translate the U1Card's index-based
        // callback into the option-shaped patch the backend's _build_unlock_picker_*
        // emitted:
        //   onUnlockSelected([i, j]) → take options[i] + options[j] target dicts,
        //                              send {selected_targets: [...]} via plan-patch
        //   onUnlockEverything()     → send the option whose target.kind == "all"
        handlers.onU1UnlockSelected = { [weak self] indices in
            guard let self, let current = self.pendingPlanArchCard else { return }
            let targets: [[String: Any]] = indices.compactMap { idx in
                guard idx < current.options.count else { return nil }
                return current.options[idx].patch["target"]?.value as? [String: Any]
            }
            guard !targets.isEmpty else { return }
            let synthesised = PlanArchCardOption(
                label: "Unlock selected",
                patch: ["selected_targets": PlanArchAnyCodable(targets)]
            )
            self.handlePlanArchOption(synthesised)
        }
        handlers.onU1UnlockEverything = { [weak self] in
            guard let self, let current = self.pendingPlanArchCard else { return }
            // The backend's "Unlock everything" option carries target.kind=="all".
            let everyOpt = current.options.first(where: { opt in
                guard let target = opt.patch["target"]?.value as? [String: Any] else {
                    return false
                }
                return (target["kind"] as? String) == "all"
            })
            if let opt = everyOpt {
                self.handlePlanArchOption(opt)
            }
        }

        // F1 / list-suggestion picker.
        // For query-source cards (Phase 2D): tapping a row prefills inputText
        // via handleQueryCardStub — NEVER posts plan-patch (spec §1 invariant 4).
        // For all other sources: onListPicked is not wired (plan-arch F1 cards
        // from the plan/event source have their own patch synthesis path).
        if card.source == .query {
            handlers.onListPicked = { [weak self] name in
                guard let self else { return }
                let opt = PlanArchCardOption(label: name, patch: [:], cancelsPlan: false)
                self.handleQueryCardStub(card: card, option: opt)
            }
        } else {
            handlers.onListPicked = nil
        }

        // D4 multi-child labels — 2A backend never emits this kind;
        // cancel defensively rather than posting a malformed patch.
        handlers.onChildrenLabelsPicked = { [weak self] _ in
            self?.handlePlanArchOption(PlanArchCardOption.cancel(fromCard: card))
        }

        // Reflection review cards need custom payloads: approve carries the
        // optional parent note, while redo confirms the already-staged reason.
        if card.kind == "reflection.confirm_approve" {
            handlers.onReflectionApprove = { [weak self] note in
                guard let self else { return }
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                let noteToSend = trimmed.isEmpty
                    ? ReflectionParentNoteFallback.thanksHonest
                    : trimmed
                let opt = PlanArchCardOption.synthesise(
                    fromCard: card,
                    patch: [
                        "intent_confirmed": true,
                        "parent_note": noteToSend,
                    ]
                )
                self.handlePlanArchOption(opt)
            }
        } else if card.kind == "reflection.confirm_redo" {
            handlers.onReflectionRedo = { [weak self] in
                guard let self else { return }
                let opt = PlanArchCardOption.synthesise(
                    fromCard: card,
                    patch: ["intent_confirmed": true]
                )
                self.handlePlanArchOption(opt)
            }
        }

        // For reflection.content_generation_failed, wire Retry / SimplerTemplate
        // via synthesised patches (spec §7.3). For all other card kinds, leave
        // onPrimary/onSecondary nil — polished cards drive their own primary action;
        // synthesising "intent_confirmed: true" would be rejected by CardPatchPayload
        // (extra="forbid") and cause silent failures.
        if card.kind == "reflection.content_generation_failed" {
            handlers.onPrimary = { [weak self] in
                guard let self else { return }
                let opt = PlanArchCardOption.synthesise(
                    fromCard: card, patch: ["intent_confirmed": true]
                )
                self.handlePlanArchOption(opt)
            }
            handlers.onSecondary = { [weak self] in
                guard let self else { return }
                let opt = PlanArchCardOption.synthesise(
                    fromCard: card, patch: ["use_simpler_template": true]
                )
                self.handlePlanArchOption(opt)
            }
        } else {
            handlers.onPrimary = nil
            handlers.onSecondary = nil
        }

        handlers.onCancel = { [weak self] in
            self?.handlePlanArchOption(PlanArchCardOption.cancel(fromCard: card))
        }

        // Tertiary is rarely used (G1 onboarding); leave nil.
        return handlers
    }
}

// MARK: - PlanArchCardOption synthesis helpers

extension PlanArchCardOption {
    /// Build an option that matches the existing plan-patch wire format.
    /// The real `PlanArchCardOption.patch` is `[String: PlanArchAnyCodable]`
    /// (NOT a single PlanArchAnyCodable wrapping the whole dict). Each
    /// top-level entry of the JSON-merge patch must be wrapped
    /// individually via `mapValues`.
    static func synthesise(
        fromCard card: PlanArchCardPayload, patch: [String: Any]
    ) -> PlanArchCardOption {
        let wrapped: [String: PlanArchAnyCodable] = patch.mapValues {
            PlanArchAnyCodable($0)
        }
        return PlanArchCardOption(
            label: "",
            patch: wrapped,
            cancelsPlan: false
        )
    }

    static func cancel(fromCard card: PlanArchCardPayload) -> PlanArchCardOption {
        return PlanArchCardOption(
            label: "Cancel",
            patch: [:],
            cancelsPlan: true
        )
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
