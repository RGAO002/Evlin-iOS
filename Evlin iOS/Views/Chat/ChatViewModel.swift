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
    /// Set while a stream's `stage` event is the most recent thing heard from
    /// the backend (e.g. "Checking tasks…"). Cleared as soon as a text delta,
    /// the terminal envelope, or an error arrives. ChatView prefers this over
    /// the generic typing-dots indicator when non-nil.
    @Published var stageText: String?

    /// Streaming is the default chat experience. This remains a KILL SWITCH:
    /// explicitly setting the key to false restores instant (non-stream)
    /// replies everywhere without a new release. Unset (the normal state) → on.
    var chatStreamingEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "evlin.chatStreamingEnabled") != nil else {
                return true
            }
            return defaults.bool(forKey: "evlin.chatStreamingEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "evlin.chatStreamingEnabled") }
    }

    /// Deltas are display-only; the terminal envelope's `message` is always
    /// authoritative (spec §3) — the typewriter's revealed-so-far text is
    /// discarded/overwritten by `finalize(with:)` regardless of similarity.
    nonisolated static func reconcileStreamedEnvelope(
        revealedSoFar: String, envelopeMessage: String
    ) -> String {
        envelopeMessage
    }

    /// Dedup guard for `stageText` — avoids redundant @Published churn / view
    /// updates when the backend repeats the same stage label.
    nonisolated static func shouldUpdateStage(current: String?, incoming: String) -> Bool {
        current != incoming
    }

    /// A stream that fails before producing user-visible output can safely
    /// degrade to the legacy JSON endpoint. Once text or the terminal envelope
    /// has arrived, avoid a second send and surface the failure in-chat.
    nonisolated static func shouldFallbackToLegacyAfterStreamFailure(
        hasReceivedText: Bool,
        hasReceivedEnvelope: Bool
    ) -> Bool {
        !hasReceivedText && !hasReceivedEnvelope
    }

    nonisolated static func visibleStreamErrorMessage(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("500") || trimmed.contains("503") {
            return "The AI model is briefly overloaded. Please tap again in a few seconds."
        }
        if trimmed.isEmpty {
            return "I couldn't finish that reply. Please try again."
        }
        return "I couldn't finish that reply. Please try again."
    }

    nonisolated static func stageClearDelay(
        elapsed: TimeInterval,
        minimumVisibleDuration: TimeInterval
    ) -> TimeInterval {
        max(0, minimumVisibleDuration - elapsed)
    }

    nonisolated static func isSafetyStatusPrompt(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("safe")
            || lowered.contains("where")
            || lowered.contains("location")
    }

    /// Local first-stage copy shown immediately after Send, before the backend
    /// has had a chance to emit a real `stage` SSE event. Backend stages still
    /// replace this as soon as they arrive.
    nonisolated static func initialStageLabel(for text: String) -> String {
        let lowered = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lowered.contains($0) }
        }

        if containsAny(["calendar", "event", "events", "schedule", "appointment"]) {
            return "Looking at the calendar…"
        }
        if containsAny(["checklist", "check list", "task", "tasks", "daily"]) {
            return "Checking tasks…"
        }
        if containsAny([
            "screen time", "lock", "block", "unblock", "limit",
            "youtube", "tiktok", "instagram", "snapchat", " app", "apps", "application"
        ]) {
            return "Checking screen time…"
        }
        return "Thinking…"
    }

    /// Retains the Timer driving the active turn's TypewriterEngine so it
    /// isn't deallocated mid-stream; invalidated once the engine has fully
    /// caught up to its buffer after `finalize(with:)`.
    private var typewriterTimer: Timer?
    private let minimumStageVisibleDuration: TimeInterval = 0.65
    private var stageShownAt: Date?
    private var stageClearTask: Task<Void, Never>?
    /// STRONG ref to the engine currently being revealed. The engine is created
    /// inside a synchronous scope (`typewriteNonStreamedText`) or an async one
    /// (`dispatchChatStreaming`) that returns BEFORE the reveal finishes; the
    /// Timer captures it weakly. Without this VM-held strong ref the engine
    /// deallocs at that scope's return and the bubble renders empty. Cleared in
    /// `invalidateTypewriterTimer` once the reveal is done/abandoned.
    private var activeTypewriterEngine: TypewriterEngine?
    /// Guards `dispatchChatLegacyOnce` so a `.fallbackToLegacy` failure can
    /// trigger the legacy JSON dispatch at most once per user message (no
    /// recursion / double-send if something upstream retries).
    private var legacyFallbackInFlight = false

    /// Multi-device gate: when the family has >1 child device we
    /// send `child_device_id: nil` so the backend disambiguation gate asks
    /// for the exact child/device instead of silently targeting the pinned one.
    /// A true single-device family keeps the stored id (fast path, no card).
    /// Pure function so it can be unit-tested without a live view model.
    nonisolated static func effectiveChildDeviceID(deviceCount: Int, storedChildDeviceID: String?) -> String? {
        deviceCount > 1 ? nil : storedChildDeviceID
    }

    /// Injected by ChatView from the family aggregate's device count. Defaults to 1
    /// so any code path that constructs a bare view model still sends the
    /// stored id (single-device behaviour) rather than nil-ing it out.
    var childDeviceCountProvider: () -> Int = { 1 }

    /// Currently-rendered confirmation card, if any. See plan Phase 9.
    /// Set when backend returns `action.card_id`, cleared when user answers.
    @Published var currentCard: (CardID, CardContext, CardHandlers)?

    /// Task 11 — currently-rendered deterministic app-control card, if any.
    /// Set when the parent-chat seam returns one of the six app-control
    /// `card_id`s (single_app_shield_advice, shield_token_missing, …) with a
    /// typed `card_payload`. Rendered by AppControlCard in ChatView, SEPARATE
    /// from the Brain/verb-table `currentCard` path. Cleared when the parent
    /// taps an option/candidate or dismisses.
    @Published var currentAppControlCard: AppControlCardModel?

    /// ProposalToken → kind for proposals whose alias didn't resolve at
    /// pre-flight. Drives ProposalCard's "Tag <target>" UI and the
    /// hard guard inside `confirmProposal(_:)`. Task 2.3 wires up the
    /// pre-flight that populates this; here we declare it so the hard
    /// guard compiles.
    @Published var pendingAliasMisses: [String: AliasKind] = [:]

    /// Non-nil when ChatView should present the lazy-tag sheet.
    @Published var activeLazyTagRequest: LazyTagRequest? = nil

    /// Non-nil when an app-control card asks the parent to search App Store
    /// because the visible candidate list did not contain the intended app.
    @Published var activeAppStoreSearchRequest: AppStoreSearchRequest? = nil

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
    /// Event-exec tokens already consumed successfully this session. The card
    /// view consults this on rebuild (tab switch) to render "✓ Added" instead
    /// of a re-tappable Confirm whose token would 410.
    var confirmedEventTokens: Set<String> = []

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

    /// Pure unpaired decision. The parent's phone can dispatch a chat command
    /// only when it knows BOTH a family to scope to AND a child device to queue
    /// the command on. Missing either means the backend would parse the message
    /// but never queue anything (a silent no-op) — so we block locally and ask
    /// the parent to pair first. Pure + nonisolated so it unit-tests without
    /// UserDefaults or network.
    nonisolated static func isUnpaired(familyID: UUID?, childDeviceID: UUID?) -> Bool {
        familyID == nil || childDeviceID == nil
    }

    let quickPrompts = QuickPrompt.defaults
    var apiClient: APIClient = APIClient()
    @Published var childName: String = "your kid"
    /// "std" | "max" — drives E1 copy branching. Read from UserDefaults at sendMessage time.
    private var protectionMode: String {
        UserDefaults.standard.string(forKey: "evlin.protectionMode") ?? "std"
    }

    /// Account-namespaced durable store for archived conversations (B2/B3).
    var chatHistoryStore: ChatHistoryStore = ChatHistoryStore()

    private var clearObserver: Any?
    private var accountSignedInObserver: Any?

    init() {
        loadMessages()
        // Only seed on a genuinely empty history (fresh install / cleared chat).
        // No stale-strategy re-seed: the neutral welcome carries no strategy
        // artifact, and a returning user's real history must never be wiped.
        if messages.isEmpty {
            seedInitialMessages()
        }
        // B4: wire the ChatHistoryStore upload seam to the real backend endpoint.
        // PUT /parent/chat/conversations/{id} through authedRequest (Bearer + 401 refresh).
        let client = apiClient
        chatHistoryStore.upload = { id, title, messages in
            let payload = ConversationUploadPayload(title: title, messages: messages)
            var req = client.authedRequest(
                path: "/parent/chat/conversations/\(id.uuidString)",
                method: "PUT"
            )
            req.httpBody = try JSONEncoder().encode(payload)
            _ = try await client.authedData(for: req)
        }
        // I1: wire fetchRemote seams so History hydrates from the backend on
        // load (list) and on open when the local blob is missing (detail).
        chatHistoryStore.fetchRemoteList = {
            let req = client.authedRequest(
                path: "/parent/chat/conversations",
                method: "GET"
            )
            let (data, _) = try await client.authedData(for: req)
            return try JSONDecoder().decode([RemoteConversationSummary].self, from: data)
        }
        chatHistoryStore.fetchRemoteDetail = { id in
            let req = client.authedRequest(
                path: "/parent/chat/conversations/\(id.uuidString)",
                method: "GET"
            )
            let (data, _) = try await client.authedData(for: req)
            return try JSONDecoder().decode(RemoteConversationDetail.self, from: data)
        }
        // Bind the account id into the history store at init so archiving is
        // NOT a silent no-op. Resolves from the AUTHORITATIVE Keychain session
        // first — the `evlin.accountID` UserDefaults mirror is fragile (onboarding
        // / child-mode flows wipe it), which silently disabled all archiving.
        ensureAccountBound()
        clearObserver = NotificationCenter.default.addObserver(
            forName: .evlinClearChat, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Remove the per-account current-conversation scratch store.
            UserDefaults.standard.removeObject(forKey: self.currentConvStorageKey)
            // Wipe all archived conversations for this account and drop the account scope.
            self.chatHistoryStore.clearAllLocal()
            self.chatHistoryStore.setAccount(nil)
            self.messages.removeAll()
            self.surfacedReflectionSubmissionIDs.removeAll()
        }
        // B5 Part 2: when a new session begins (sign-in or restore) wire the account
        // so archives immediately work for this user.
        accountSignedInObserver = NotificationCenter.default.addObserver(
            forName: .evlinAccountSignedIn, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["account_id"] as? String,
                  let accountID = UUID(uuidString: raw)
            else { return }
            self.chatHistoryStore.setAccount(accountID)
        }
        rebuildSurfacedReflectionSubmissionIndex()
        resumePendingAckPolls()
    }

    nonisolated deinit {}

    func setChildName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != childName else { return }
        childName = trimmed
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

    /// Account-scoped UserDefaults key for the live (in-progress) conversation messages.
    /// Format: `chatconv.<accountID>.current` where accountID comes from `evlin.accountID`.
    /// Falls back to a non-namespaced key when no account is set (pre-sign-in safety net).
    private var currentConvStorageKey: String {
        let accountID = UserDefaults.standard.string(forKey: "evlin.accountID") ?? "anon"
        return "chatconv.\(accountID).current"
    }

    /// Persists the current (non-seed) messages using an account-namespaced key.
    /// Synchronous — called from `messages` didSet. Seed messages are excluded.
    private func saveMessages() {
        let realMessages = messages.filter { !$0.isSeed }
        guard !realMessages.isEmpty else { return }
        let toSave = Array(realMessages.suffix(50))
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: currentConvStorageKey)
        }
        // Auto-archive: the moment a conversation has any real content it is
        // durably saved into history and kept fresh as new messages arrive.
        // This is what makes EVERY conversation — including the very first /
        // default one — show up in "Past conversations" and stay restorable,
        // without the parent having to rename it or tap "New chat" first.
        currentConversationMaterialized = true
        persistCurrentConversation()
    }

    /// Loads the current (in-progress) conversation from account-namespaced storage.
    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: currentConvStorageKey),
              let saved = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !saved.isEmpty else { return }
        messages = saved
    }

    func clearHistory() {
        messages.removeAll()
        surfacedReflectionSubmissionIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: currentConvStorageKey)
    }

    /// Archive current conversation (if non-empty) and reset to a fresh seed.
    /// This is the "Clear" action in the UI.
    func clear() {
        let realMessages = messages.filter { !$0.isSeed }
        if !realMessages.isEmpty {
            // Capture state before rotating.
            let convID = currentConversationID
            let stored = realMessages.prefix(50).map { StoredChatMessage(sanitizing: $0) }
            // Preserve a manual rename; only fall back to a derived label.
            let title = currentConversationTitle ?? Self.derivedTitle(from: realMessages)
            Task { [weak self] in
                guard let self else { return }
                await self.chatHistoryStore.archiveCurrent(
                    id: convID,
                    title: title,
                    messages: Array(stored)
                )
            }
        }
        // Rotate conversation id.
        let fresh = UUID()
        conversationIdString = fresh.uuidString
        // Reset title for the new conversation.
        currentConversationTitle = nil
        // Reset to seed.
        surfacedReflectionSubmissionIDs.removeAll()
        seedInitialMessages()
        currentConversationMaterialized = false
        didAttemptAutoTitle = false
    }

    // MARK: - Strategy-agent T11 / B3: conversation_id + answer-question + feedback

    @AppStorage("evlin.conversation_id") var conversationIdString: String = ""

    /// Stable per-conversation UUID; rotated on `clear()` / set on `open(id:)`.
    /// Sent on every /parent/chat turn and feedback call.
    var currentConversationID: UUID {
        if let u = UUID(uuidString: conversationIdString) { return u }
        let fresh = UUID()
        conversationIdString = fresh.uuidString
        return fresh
    }

    // MARK: - B6: conversation title / rename

    /// Mutable display title for the current conversation. Defaults to nil
    /// (shows "Evlin" in the top bar). The pencil rename overrides it.
    @Published var currentConversationTitle: String? = nil

    /// Rename the current conversation in-memory and persist via
    /// `chatHistoryStore`. The title is reset to nil on `clear()`.
    /// When the trimmed title is empty, the in-memory title is set to nil
    /// (top bar shows "Evlin") and no empty string is persisted.
    func renameCurrentConversation(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentConversationTitle = nil
            // Do not persist an empty title — leave any prior stored title as-is
            // (the in-memory nil already drives the bar back to "Evlin").
        } else {
            currentConversationTitle = trimmed
            // Renaming MATERIALIZES the conversation: persist it to saved history
            // now (so a named conversation is kept even before it is cleared) and
            // keep it fresh as later messages arrive (see saveMessages).
            currentConversationMaterialized = true
            persistCurrentConversation()
        }
    }

    /// True once the current conversation has been promoted into saved history
    /// (renamed, or opened from history). While true, every message change
    /// re-persists it so the saved copy never goes stale.
    private var currentConversationMaterialized = false

    /// One-shot guard so the AI auto-title fires at most once per conversation.
    /// Reset on clear()/new-chat. The `currentConversationTitle == nil` check is
    /// the real precedence gate (a manual rename or an already-applied title
    /// both make it non-nil), so a rename always wins.
    private var didAttemptAutoTitle = false

    /// ChatGPT-style auto-title: when the parent sends the FIRST message in a
    /// new, un-renamed conversation, ask the backend for a concise title and
    /// apply it (updates the top bar + the History entry). Fire-and-forget — on
    /// any failure the conversation keeps its derived first-message title.
    private func maybeAutoTitle(firstMessage: String) {
        guard currentConversationTitle == nil, !didAttemptAutoTitle else { return }
        let parentCount = messages.filter { $0.role == .parent && !$0.isSeed }.count
        guard parentCount == 1 else { return }
        didAttemptAutoTitle = true
        Task { [weak self] in
            guard let self else { return }
            guard let title = try? await self.apiClient.generateConversationTitle(firstMessage: firstMessage),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            await MainActor.run {
                // Respect a manual rename that may have landed in the meantime.
                guard self.currentConversationTitle == nil else { return }
                self.currentConversationTitle = title
                self.currentConversationMaterialized = true
                self.persistCurrentConversation()
            }
        }
    }

    /// Upsert the current conversation into `chatHistoryStore` (local-first +
    /// best-effort backend PUT) with its current title + sanitized real messages.
    /// Resolve the account scope from the AUTHORITATIVE Keychain session first,
    /// falling back to the (fragile) `evlin.accountID` UserDefaults mirror. nil
    /// only when there is genuinely no session.
    private func resolveAccountID() -> UUID? {
        if let raw = KeychainStore.shared.load()?.accountID,
           let id = UUID(uuidString: raw) { return id }
        if let raw = UserDefaults.standard.string(forKey: "evlin.accountID"),
           let id = UUID(uuidString: raw) { return id }
        return nil
    }

    /// Bind the history store to the current account if it isn't already bound.
    /// Cheap when already bound (no Keychain read). Safe to call repeatedly —
    /// called at init and before every archive/open so a wiped UserDefaults
    /// mirror can never silently disable archiving again.
    private func ensureAccountBound() {
        guard chatHistoryStore.boundAccountID == nil else { return }
        guard let id = resolveAccountID() else { return }
        chatHistoryStore.setAccount(id)
    }

    private func persistCurrentConversation() {
        ensureAccountBound()
        let convID = currentConversationID
        let real = messages.filter { !$0.isSeed }
        // Use the explicit (renamed) title when set; otherwise derive a stable
        // label from the first parent message so the history list shows
        // something identifiable instead of a wall of "Evlin".
        let title = currentConversationTitle ?? Self.derivedTitle(from: real)
        let stored = real.prefix(50).map { StoredChatMessage(sanitizing: $0) }
        Task { [weak self] in
            await self?.chatHistoryStore.archiveCurrent(id: convID, title: title, messages: Array(stored))
        }
    }

    /// Fallback display title for an un-renamed conversation: the first parent
    /// message trimmed to ~40 chars. nil when no parent message exists yet (the
    /// history row then falls back to "Evlin" + preview).
    private static func derivedTitle(from messages: [ChatMessage]) -> String? {
        guard let first = messages.first(where: { $0.role == .parent })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty
        else { return nil }
        return first.count > 40 ? String(first.prefix(40)) + "…" : first
    }

    // MARK: - B7: open a saved conversation (inert, no ack polls)

    /// Load a previously archived conversation from `chatHistoryStore` and
    /// replace the current message list with inert versions of its messages.
    ///
    /// Inert guarantee: `StoredChatMessage.asInertChatMessage()` returns messages
    /// with `commandID == nil` and a terminal (or nil) `receiptState`, so the
    /// existing `resumePendingAckPolls` guard
    /// (`role == .agent && receiptState == .pending && commandID != nil`) can
    /// never fire. We do NOT call `resumePendingAckPolls` or
    /// `reconcilePendingReceipts` after loading these messages.
    func openConversation(_ id: UUID) async {
        ensureAccountBound()
        let stored = await chatHistoryStore.open(id)
        let inert = stored.map { $0.asInertChatMessage() }
        // Set the conversation id to the one being opened so any subsequent
        // sends belong to the same conversation thread.
        conversationIdString = id.uuidString
        // Update the title to match the saved summary.
        let summary = chatHistoryStore.conversations.first(where: { $0.id == id })
        currentConversationTitle = summary?.title
        // An opened conversation is already saved — keep it materialized so
        // further messages re-persist into history.
        currentConversationMaterialized = true
        // Wipe live card state — we're restoring a finished conversation.
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        currentCard = nil
        currentAppControlCard = nil
        surfacedReflectionSubmissionIDs.removeAll()
        // Replace the message list (triggers saveMessages but inert messages
        // are well-formed ChatMessages so no data is lost).
        // I2: when the (post-hydrate) list is empty, seed the welcome message
        // rather than injecting a blank agent bubble. Otherwise prepend the same
        // tutorial/fastpath seed ABOVE the restored messages so a reopened
        // conversation shows the welcome guide just like a fresh one. The seed
        // is `isSeed = true`, so it is never re-archived or sent as history.
        if inert.isEmpty {
            seedInitialMessages()
        } else {
            messages = [makeSeedMessage()] + inert
        }
    }

    /// Strategy-agent T11.11 — POST /parent/chat/answer-question and feed
    /// the response back through the existing chat pipeline.
    /// B4: routes through apiClient.authedData (Bearer + 401 refresh).
    /// Note: answer-question body does NOT include conversation_id; the server
    /// derives the conversation from the stored pending question.
    func sendAnswer(_ body: AnswerQuestionBody) async {
        // The answered question is no longer actionable. Clear it immediately;
        // the response may replace it with a proposal card.
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        var req = apiClient.authedRequest(path: "/parent/chat/answer-question", method: "POST")
        req.httpBody = try? JSONEncoder().encode(body)
        self.isThinking = true
        defer { self.isThinking = false }
        do {
            let (data, _) = try await apiClient.authedData(for: req)
            let response = try JSONDecoder().decode(APIClient.ChatResponse.self, from: data)
            self.handleAnswerQuestionResponse(response, rawData: data)
        } catch {
            print("answer-question failed: \(error)")
        }
    }

    /// `/parent/chat/answer-question` returns the same response envelope as
    /// `/parent/chat`, including plan-arch cards in raw `card_payload(s)`.
    /// Keep that card parsing path identical so follow-up answers can produce
    /// reflection/task/phone confirmation cards.
    func handleAnswerQuestionResponse(_ response: APIClient.ChatResponse, rawData: Data) {
        lastResponseViaFastpath = response.viaFastpath ?? false
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        if tryHandlePlanArchCard(from: rawData, message: response.message) {
            isThinking = false
            return
        }
        if tryHandleAppControlCard(from: rawData, response: response) {
            isThinking = false
            return
        }
        processResponse(response, userMessage: "")
    }

    /// Strategy-agent T11.11 — POST 👍/👎 feedback for an assistant turn.
    /// B4: routes through authedRequest (Bearer + 401 refresh) via FeedbackService.
    func sendFeedback(messageId: String, rating: ChatFeedbackRating) async {
        try? await FeedbackService(client: apiClient).submit(
            conversationId: currentConversationID,
            messageId: messageId,
            rating: rating
        )
    }

    // MARK: - Send

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Unpaired guard (beta P0 C2): if this phone isn't paired to a family
        // with a child device, the backend would parse but never queue the
        // command — a silent no-op. Block locally and surface a pairing CTA
        // instead of pretending the message went through. We deliberately do
        // NOT append a parent bubble or clear `inputText`, so the parent can
        // pair and retry the exact same message.
        let ids = currentFamilyAndChildIDs()
        if Self.isUnpaired(familyID: ids.familyID, childDeviceID: ids.childDeviceID) {
            messages.append(ChatMessage(
                role: .agent,
                content: "Pair a child's device first so I can actually lock apps and set limits. Open Settings to start pairing — then send this again.",
                timestamp: Date()
            ))
            return
        }

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
        currentAppControlCard = nil

        messages.append(ChatMessage(role: .parent, content: text, timestamp: Date()))
        inputText = ""
        isThinking = true
        errorMessage = nil

        // ChatGPT-style: the first message in a new, un-renamed conversation
        // gets an AI-generated title (fire-and-forget; falls back silently).
        maybeAutoTitle(firstMessage: text)

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
        currentAppControlCard = nil
        isThinking = true
        errorMessage = nil
        lastUserMessageForCard = lastUser

        dispatchChat(userMessage: lastUser, forceConfirmations: [], skipFastpath: true)
    }

    // MARK: - Seed initial messages

    /// Client-injected tutorial seed (spec §3.2). Never persisted, never archived,
    /// never sent to the backend as history context. `isSeed = true` marks it for
    /// exclusion from archives and from the `/parent/chat` `history` list.
    func seedInitialMessages() {
        messages = [makeSeedMessage()]
    }

    /// Build the tutorial/fastpath welcome bubble. `isSeed = true` excludes it
    /// from archives and from the `/parent/chat` history context. Extracted so a
    /// restored conversation can also show the tutorial at the top.
    private func makeSeedMessage() -> ChatMessage {
        let kid = childName.isEmpty ? "your kid" : childName
        var seed = ChatMessage(
            role: .agent,
            content: """
            Hi, I'm Evlin. Tell me what you want in plain English and I'll take care of \
            it for \(kid). A few things you can ask:

            Lock & block — "Lock \(kid)'s phone for 30 minutes" · "Block TikTok for 1 \
            hour" · "Unblock TikTok"
            Limits & check-ins — "Give \(kid) a 2-hour daily limit" · "How much has \
            \(kid) used today?"
            Tasks — "Add a task: clean your room"
            Calendar — "What's on the calendar today?" · "Schedule soccer at 4pm"

            No exact wording needed — just ask. Tap Clear to save this chat and start \
            fresh.
            """,
            timestamp: Date()
        )
        seed.isSeed = true
        return seed
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
        childDeviceIDOverride: UUID? = nil
    ) {
        if chatStreamingEnabled {
            legacyFallbackInFlight = false
            Task { [weak self] in
                await self?.dispatchChatStreaming(
                    userMessage: userMessage,
                    forceConfirmations: forceConfirmations,
                    skipFastpath: skipFastpath,
                    childDeviceIDOverride: childDeviceIDOverride
                )
            }
            return
        }
        dispatchChatLegacy(
            userMessage: userMessage,
            forceConfirmations: forceConfirmations,
            skipFastpath: skipFastpath,
            childDeviceIDOverride: childDeviceIDOverride
        )
    }

    /// The pre-existing (non-streaming) JSON dispatch, unchanged in behavior.
    /// Extracted verbatim out of `dispatchChat` so the streaming path's
    /// `.fallbackToLegacy` failure can invoke it directly without recursing
    /// back through the `chatStreamingEnabled` gate.
    private func dispatchChatLegacy(
        userMessage: String,
        forceConfirmations: [String],
        skipFastpath: Bool = false,
        childDeviceIDOverride: UUID? = nil
    ) {
        // Exclude the seed message from history sent to backend (spec §3.2).
        let history: [[String: String]] = messages.filter { !$0.isSeed }.suffix(10).map { msg in
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
                    skipFastpath: skipFastpath,
                    childDeviceIDOverride: childDeviceIDOverride
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
                let attachSafetyCard = Self.isSafetyStatusPrompt(userMessage)
                if await MainActor.run(body: {
                    self.tryHandlePlanArchCard(
                        from: rawData,
                        message: resp.message,
                        debugTurnID: turnID,
                        attachSafetyCard: attachSafetyCard
                    )
                }) {
                    await MainActor.run { self.isThinking = false }
                    return
                }
                // Task 11 app-control cards: caught BEFORE processResponse so
                // they take the AppControlCard render path instead of the Brain
                // CardDispatcher path (their card_id resolves to a CardID but is
                // intentionally a no-op in renderCard's Brain switches).
                if await MainActor.run(body: {
                    self.tryHandleAppControlCard(
                        from: rawData,
                        response: resp,
                        debugTurnID: turnID,
                        attachSafetyCard: attachSafetyCard
                    )
                }) {
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

    /// Streaming twin of `dispatchChatLegacy`. Terminal envelope goes through
    /// the SAME `processResponse` path; the only difference is the
    /// pre-envelope display (stage line + incrementally revealed bubble).
    @MainActor
    private func dispatchChatStreaming(
        userMessage: String,
        forceConfirmations: [String],
        skipFastpath: Bool,
        childDeviceIDOverride: UUID?
    ) async {
        errorMessage = nil
        let body: Data
        do {
            body = try makeChatRequestBody(
                userMessage: userMessage,
                forceConfirmations: forceConfirmations,
                skipFastpath: skipFastpath,
                childDeviceIDOverride: childDeviceIDOverride
            )
        } catch {
            errorMessage = error.localizedDescription
            isThinking = false
            return
        }
        let client = ChatStreamClient(apiClient: apiClient)
        var engine: TypewriterEngine?
        var streamBubbleID: UUID?
        var receivedStreamText = false
        var receivedEnvelope = false
        showStage(Self.initialStageLabel(for: userMessage))
        do {
            for try await ev in client.stream(body: body) {
                switch ev {
                case .stage(_, let label):
                    showStage(label)
                case .textDelta(let t):
                    clearStageAfterMinimumVisibility()
                    if !t.isEmpty {
                        receivedStreamText = true
                    }
                    if engine == nil {
                        let msg = ChatMessage(role: .agent, content: "", timestamp: Date())
                        messages.append(msg)
                        streamBubbleID = msg.id
                        let e = TypewriterEngine()
                        let bubbleID = msg.id
                        e.onChange = { [weak self] text in
                            self?.updateStreamBubble(id: bubbleID, text: text)
                        }
                        startTypewriterTimer(e)
                        engine = e
                    }
                    engine?.append(t)
                    engine?.flushNow()
                case .envelope(let data):
                    clearStageAfterMinimumVisibility()
                    receivedEnvelope = true
                    do {
                        let decoded = try JSONDecoder().decode(APIClient.ChatResponse.self, from: data)
                        if let e = engine {
                            e.finalize(with: Self.reconcileStreamedEnvelope(
                                revealedSoFar: e.revealed, envelopeMessage: decoded.message))
                            e.flushNow()
                        }
                        // Same post-decode pipeline as sendChatMessageWithRawData
                        // (card handlers see rawData; the text bubble goes
                        // through processResponse with the new reuse param).
                        lastResponseViaFastpath = decoded.viaFastpath ?? false
                        handleStreamEnvelope(
                            decoded, rawData: data,
                            userMessage: userMessage,
                            reuseTextBubbleID: streamBubbleID
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                        appendVisibleStreamError(error.localizedDescription)
                    }
                case .error(let message):
                    clearStageNow()
                    appendVisibleStreamError(message)
                    // Terminal error with no finalize — stop the reveal so the
                    // timer doesn't idle forever holding the engine.
                    invalidateTypewriterTimer()
                }
            }
        } catch let failure as StreamFailure {
            clearStageNow()
            switch failure {
            case .fallbackToLegacy:
                // Pre-headers failure: no stream engine was started here, and
                // the legacy dispatch starts its OWN typewriter — do NOT stop.
                dispatchChatLegacyOnce(
                    userMessage: userMessage,
                    forceConfirmations: forceConfirmations,
                    skipFastpath: skipFastpath,
                    childDeviceIDOverride: childDeviceIDOverride
                )
                return
            case .manualRetry(let msg):
                invalidateTypewriterTimer()
                if Self.shouldFallbackToLegacyAfterStreamFailure(
                    hasReceivedText: receivedStreamText,
                    hasReceivedEnvelope: receivedEnvelope
                ) {
                    dispatchChatLegacyOnce(
                        userMessage: userMessage,
                        forceConfirmations: forceConfirmations,
                        skipFastpath: skipFastpath,
                        childDeviceIDOverride: childDeviceIDOverride
                    )
                    return
                }
                appendVisibleStreamError(msg)
            case .signedOut:
                handleSignedOut()
                invalidateTypewriterTimer()
            }
        } catch {
            clearStageNow()
            invalidateTypewriterTimer()
            if Self.shouldFallbackToLegacyAfterStreamFailure(
                hasReceivedText: receivedStreamText,
                hasReceivedEnvelope: receivedEnvelope
            ) {
                dispatchChatLegacyOnce(
                    userMessage: userMessage,
                    forceConfirmations: forceConfirmations,
                    skipFastpath: skipFastpath,
                    childDeviceIDOverride: childDeviceIDOverride
                )
                return
            }
            appendVisibleStreamError(error.localizedDescription)
        }
        // DO NOT invalidate the typewriter timer here. The reveal is
        // asynchronous and OUTLIVES this stream loop: on the common
        // envelope-only (fastpath) path the bubble+engine+timer are created
        // inside the envelope handler and the text is revealed over the next
        // ~180ms of ticks. Killing the timer here (synchronously, right after
        // the loop ends) stops it before its first tick, so `revealed` stays
        // "" and the bubble renders empty. The timer self-invalidates in its
        // own callback once `revealed == buffer` (startTypewriterTimer).
        isThinking = false
    }

    @MainActor
    private func appendVisibleStreamError(_ detail: String) {
        errorMessage = detail
        messages.append(ChatMessage(
            role: .agent,
            content: Self.visibleStreamErrorMessage(detail),
            timestamp: Date()
        ))
        isThinking = false
    }

    @MainActor
    private func showStage(_ label: String) {
        stageClearTask?.cancel()
        if Self.shouldUpdateStage(current: stageText, incoming: label) {
            stageText = label
            stageShownAt = Date()
        }
    }

    @MainActor
    private func clearStageAfterMinimumVisibility() {
        guard let shownAt = stageShownAt else {
            clearStageNow()
            return
        }
        let delay = Self.stageClearDelay(
            elapsed: Date().timeIntervalSince(shownAt),
            minimumVisibleDuration: minimumStageVisibleDuration
        )
        guard delay > 0 else {
            clearStageNow()
            return
        }
        stageClearTask?.cancel()
        stageClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.clearStageNow()
            }
        }
    }

    @MainActor
    private func clearStageNow() {
        stageClearTask?.cancel()
        stageClearTask = nil
        stageShownAt = nil
        stageText = nil
    }

    /// Mirrors `sendChatMessageWithRawData`'s post-decode section (dispatchChatLegacy):
    /// plan-arch card, then app-control card, then the unified `processResponse`
    /// path — but reusing the streamed text bubble instead of appending a new one.
    @MainActor
    private func handleStreamEnvelope(
        _ resp: APIClient.ChatResponse,
        rawData: Data,
        userMessage: String,
        reuseTextBubbleID: UUID?
    ) {
        let attachSafetyCard = Self.isSafetyStatusPrompt(userMessage)
        if tryHandlePlanArchCard(
            from: rawData,
            message: resp.message,
            reuseTextBubbleID: reuseTextBubbleID,
            attachSafetyCard: attachSafetyCard
        ) {
            isThinking = false
            return
        }
        if tryHandleAppControlCard(
            from: rawData,
            response: resp,
            reuseTextBubbleID: reuseTextBubbleID,
            attachSafetyCard: attachSafetyCard
        ) {
            isThinking = false
            return
        }
        processResponse(
            resp,
            userMessage: userMessage,
            reuseTextBubbleID: reuseTextBubbleID
        )
    }

    /// Runs the existing non-streaming JSON dispatch at most once per user
    /// message — used as the `.fallbackToLegacy` recovery path so a stream
    /// endpoint that's unreachable/missing (404/405/501) degrades gracefully
    /// instead of leaving the parent stuck. Guarded so a caller that retries
    /// can't trigger a double-send.
    @MainActor
    private func dispatchChatLegacyOnce(
        userMessage: String,
        forceConfirmations: [String],
        skipFastpath: Bool,
        childDeviceIDOverride: UUID?
    ) {
        guard !legacyFallbackInFlight else { return }
        legacyFallbackInFlight = true
        dispatchChatLegacy(
            userMessage: userMessage,
            forceConfirmations: forceConfirmations,
            skipFastpath: skipFastpath,
            childDeviceIDOverride: childDeviceIDOverride
        )
    }

    /// Updates the streamed bubble's content in place as the typewriter
    /// engine reveals more of the buffered text. No-op if the bubble was
    /// somehow removed mid-stream (e.g. Clear chat).
    @MainActor
    private func updateStreamBubble(id: UUID?, text: String) {
        guard let id else { return }
        mutateMessage(id: id) { message in
            message.content = text
        }
    }

    /// Mutating a field inside a `@Published` array element is easy for SwiftUI
    /// to miss. Replace the value through the array so `messages` publishes.
    @MainActor
    @discardableResult
    private func mutateMessage(id: UUID, _ mutate: (inout ChatMessage) -> Void) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return false }
        var next = messages
        mutate(&next[idx])
        messages = next
        return true
    }

    @MainActor
    @discardableResult
    private func appendOrReuseAgentTextBubble(
        reuseTextBubbleID: UUID?,
        text: String,
        debugTurnID: String?,
        attachSafetyCard: Bool,
        typewriteWhenAppending: Bool = true
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reuseID = reuseTextBubbleID,
           mutateMessage(id: reuseID, { message in
               message.debugTurnID = Self.bubbleDebugTurnID(debugTurnID)
               if attachSafetyCard { message.isSafetyCard = true }
           }) {
            return true
        }
        guard !trimmed.isEmpty else { return false }

        var message = ChatMessage(
            role: .agent,
            content: typewriteWhenAppending && chatStreamingEnabled ? "" : trimmed,
            timestamp: Date(),
            debugTurnID: Self.bubbleDebugTurnID(debugTurnID)
        )
        if attachSafetyCard { message.isSafetyCard = true }
        messages.append(message)
        if typewriteWhenAppending && chatStreamingEnabled {
            typewriteNonStreamedText(trimmed, bubbleID: message.id)
        }
        return true
    }

    /// `Timer.scheduledTimer` on the main run loop driving `engine.tick()`
    /// every 30ms (spec §5.3). Retained on the VM (`typewriterTimer`) so it
    /// isn't deallocated mid-stream; invalidated once the engine has fully
    /// caught up to its buffer post-finalize.
    @MainActor
    private func startTypewriterTimer(_ engine: TypewriterEngine) {
        typewriterTimer?.invalidate()
        // Hold the engine strongly for the reveal's lifetime — it outlives the
        // dispatch scope that created it (see `activeTypewriterEngine`).
        activeTypewriterEngine = engine
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self, let engine = self.activeTypewriterEngine else {
                self?.invalidateTypewriterTimer()
                return
            }
            engine.tick()
            // Stop ONLY when finalized AND fully revealed. A transient
            // `revealed == buffer` between streamed deltas must NOT stop the
            // timer, or later deltas never get revealed.
            if engine.isComplete {
                self.invalidateTypewriterTimer()
            }
        }
    }

    @MainActor
    private func invalidateTypewriterTimer() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        activeTypewriterEngine = nil
    }

    /// Terminal refresh failure on the stream path (`StreamFailure.signedOut`).
    /// `ChatStreamClient` calls `refreshAccessTokenSingleFlight` directly
    /// (bypassing `authedData`, which is what normally posts this
    /// notification on terminal failure), so this mirrors that same
    /// signed-out signal for the app-wide `AuthService` observer (see
    /// APIClient.swift's `.evlinSessionSignedOut`).
    @MainActor
    private func handleSignedOut() {
        KeychainStore.shared.clear()
        NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
        errorMessage = "You've been signed out. Please sign in again."
    }

    @MainActor
    private func processResponse(
        _ resp: APIClient.ChatResponse,
        userMessage: String,
        debugTurnID: String? = nil,
        reuseTextBubbleID: UUID? = nil
    ) {
        let bubbleDebugTurnID = Self.bubbleDebugTurnID(debugTurnID)
        // If a deterministic app-control card was just acted on, the follow-up
        // response is usually a plain queued-command receipt. Do not leave the
        // previous card visible after the backend accepted the choice.
        currentAppControlCard = nil

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
        // LockConfirmationCard was mock UI ("Child's device has been restricted")
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
        // Restore safety-card heuristic that was lost in d86772c refactor.
        // When the parent asks "is X safe", "where is X", or "X's location",
        // attach the SafetyStatusCard + SafetyActionButtons (location pin +
        // call) to the agent's reply. The card is rendered by ChatView when
        // isSafetyCard == true.
        let isSafety = Self.isSafetyStatusPrompt(userMessage)

        // Streaming path: the bubble already exists (typewriter engine wrote
        // the revealed deltas into it) — update its content + metadata in
        // place instead of appending a second bubble for the same turn.
        if let reuseID = reuseTextBubbleID, mutateMessage(id: reuseID, { message in
            message.reasoning = resp.reasoning
            message.debugTurnID = bubbleDebugTurnID
            if isSafety { message.isSafetyCard = true }
        }) {
            isThinking = false
            return
        }

        // Uniform typewriter (choice A, Task 9): a NEW agent text bubble from
        // a live (non-stream) response gets the SAME reveal treatment as the
        // streamed delta path, gated behind the one flag. History hydration
        // and restored conversations never reach `processResponse` — they
        // assign `messages` directly (see `loadMessages`/`seedInitialMessages`)
        // — so only live turns are affected.
        if chatStreamingEnabled {
            var msg = ChatMessage(
                role: .agent, content: "", timestamp: Date(),
                reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
            )
            if isSafety { msg.isSafetyCard = true }
            messages.append(msg)
            typewriteNonStreamedText(resp.message, bubbleID: msg.id)
            isThinking = false
            return
        }

        var msg = ChatMessage(
            role: .agent, content: resp.message, timestamp: Date(),
            reasoning: resp.reasoning, action: nil, debugTurnID: bubbleDebugTurnID
        )
        if isSafety { msg.isSafetyCard = true }
        messages.append(msg)
        isThinking = false
    }

    /// Uniform typewriter for a non-streamed (fastpath/instant) reply: reuses
    /// the exact `TypewriterEngine` + 0.03s Timer machinery the streaming path
    /// (`dispatchChatStreaming`) drives via `startTypewriterTimer`. The whole
    /// text arrives at once, so it's pushed straight through `append` +
    /// `finalize` — the finalize deadline-countdown guarantees the reveal
    /// completes within 200 ms regardless of length, while short fastpath
    /// replies still get the base reveal-rate drip (backlog/6 per tick).
    @MainActor
    private func typewriteNonStreamedText(_ text: String, bubbleID: UUID) {
        let engine = TypewriterEngine()
        engine.onChange = { [weak self] revealed in
            self?.updateStreamBubble(id: bubbleID, text: revealed)
        }
        startTypewriterTimer(engine)
        engine.append(text)
        engine.finalize(with: text)
        engine.flushNow()
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

    // MARK: - Task 11: deterministic app-control cards

    /// Detect + render one of the six deterministic app-control cards from the
    /// raw chat-response body. Returns true when handled (caller skips the
    /// Brain `processResponse` path). Mirrors `tryHandlePlanArchCard`: reads the
    /// top-level `card_payload` dict, parses it into an `AppControlCardModel`,
    /// stashes it in `currentAppControlCard`, and appends a text bubble when the
    /// backend supplied a non-empty message.
    ///
    /// Backwards-compatible: legacy responses and Brain cards have either no
    /// `card_payload` or a `card_id` that isn't an app-control id, so this
    /// returns false and the existing path runs untouched.
    @MainActor
    @discardableResult
    func tryHandleAppControlCard(
        from data: Data,
        response: APIClient.ChatResponse,
        debugTurnID: String? = nil,
        reuseTextBubbleID: UUID? = nil,
        attachSafetyCard: Bool = false
    ) -> Bool {
        guard let cardID = response.action?.card_id,
              CardID(rawValue: cardID)?.isAppControlCard == true,
              let payload = Self.appControlPayloadDict(from: data, cardID: cardID),
              let model = AppControlCardModel.parse(cardID: cardID, payload: payload)
        else { return false }

        // Replace any prior Brain/plan-arch card surfaces — this card supersedes.
        currentCard = nil
        pendingPlanArchCard = nil
        pendingPlanArchCardQueue = []
        currentAppControlCard = model

        // Append a text bubble only when the backend supplied a meaningful
        // message distinct from the card body (avoids duplicating the card copy).
        let trimmed = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reuseID = reuseTextBubbleID,
           mutateMessage(id: reuseID, { message in
               message.debugTurnID = Self.bubbleDebugTurnID(debugTurnID)
               if attachSafetyCard { message.isSafetyCard = true }
           }) {
            return true
        }
        if !trimmed.isEmpty,
           trimmed != model.body.trimmingCharacters(in: .whitespacesAndNewlines) {
            appendOrReuseAgentTextBubble(
                reuseTextBubbleID: nil,
                text: trimmed,
                debugTurnID: debugTurnID,
                attachSafetyCard: attachSafetyCard
            )
        }
        return true
    }

    /// Pull the app-control `card_payload` dict out of arbitrary chat-response
    /// JSON Data. Prefers the singular `card_payload`; falls back to the first
    /// entry of `card_payloads`. Only returns a dict whose `card_id` matches the
    /// app-control id we resolved from `action.card_id`.
    nonisolated static func appControlPayloadDict(from data: Data, cardID: String) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func matches(_ dict: [String: Any]) -> Bool {
            (dict["card_id"] as? String) == cardID
        }
        if let single = json["card_payload"] as? [String: Any], matches(single) {
            return single
        }
        if let list = json["card_payloads"] as? [[String: Any]],
           let first = list.first(where: matches) {
            return first
        }
        return nil
    }

    /// Parent tapped an option on an app-control card. Route per the option's
    /// deterministic action (force-confirmation resend / lazy-tag / rename).
    @MainActor
    func handleAppControlOption(_ option: AppControlCardOption) {
        guard let card = currentAppControlCard else { return }
        let action = AppControlRouter.route(option: option, card: card)
        applyAppControlAction(action, card: card)
    }

    /// Parent tapped a disambiguation candidate row.
    @MainActor
    func handleAppControlCandidate(_ candidate: AppControlCandidate) {
        guard let card = currentAppControlCard else { return }
        let action = AppControlRouter.route(candidate: candidate, card: card)
        applyAppControlAction(action, card: card)
    }

    /// Dismiss the app-control card without acting.
    @MainActor
    func dismissAppControlCard() {
        currentAppControlCard = nil
    }

    @MainActor
    private func applyAppControlAction(_ action: AppControlAction, card: AppControlCardModel) {
        currentAppControlCard = nil
        let selectedDeviceID = card.childDeviceID.flatMap(UUID.init(uuidString:))
        switch action {
        case .resendForceConfirmations(let tokens):
            // Re-dispatch the original parent message with the seam's tokens —
            // identical mechanism to the Brain U1/A1/B1 resend.
            let original = lastUserMessageForCard.isEmpty
                ? (messages.reversed().first(where: { $0.role == .parent })?.content ?? "")
                : lastUserMessageForCard
            guard !original.isEmpty else { return }
            isThinking = true
            dispatchChat(
                userMessage: original,
                forceConfirmations: tokens,
                childDeviceIDOverride: selectedDeviceID
            )
        case .resendPhrase(let phrase):
            // Append a parent bubble for the disambiguated phrase, then dispatch.
            resendWithPhrase(phrase, childDeviceIDOverride: selectedDeviceID)
        case .confirmAppAndResend(let candidateDisplay, let bundleID, let artworkURL):
            let original = lastUserMessageForCard.isEmpty
                ? (messages.reversed().first(where: { $0.role == .parent })?.content ?? "")
                : lastUserMessageForCard
            let rewritten = AppControlRouter.rewriteOriginalCommand(
                original,
                replacing: card.targetDisplay,
                with: candidateDisplay
            )

            guard let bundleID, !bundleID.isEmpty else {
                // Without a bundle id there is nothing durable to confirm. Keep
                // the verb/duration rewrite so we do not fall back to sending
                // just the display name.
                resendWithPhrase(rewritten, childDeviceIDOverride: selectedDeviceID)
                return
            }

            guard let familyID = currentFamilyAndChildIDs().familyID else {
                messages.append(ChatMessage(
                    role: .agent,
                    content: "I couldn't save that app choice because this phone is not paired to a family yet.",
                    timestamp: Date()
                ))
                return
            }

            isThinking = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.apiClient.confirmFamilyApp(FamilyAppConfirmation(
                        familyID: familyID,
                        canonicalName: candidateDisplay,
                        bundleID: bundleID,
                        artworkURL: artworkURL,
                        alias: card.targetDisplay,
                        source: "app_store_confirmed"
                    ))
                    await MainActor.run {
                        self.resendWithPhrase(
                            rewritten,
                            childDeviceIDOverride: selectedDeviceID
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.isThinking = false
                        self.messages.append(ChatMessage(
                            role: .agent,
                            content: "I couldn't save that app choice. Try again.",
                            timestamp: Date()
                        ))
                    }
                }
            }
        case .openLazyTag(let target, let kind):
            // Open the catalog-backed lazy-tag picker. Synthetic request token —
            // there's no proposal/pendingAliasMiss behind an app-control card, so
            // handleTagSelection's miss-sweep is a harmless no-op.
            activeLazyTagRequest = LazyTagRequest(
                proposalToken: "app-control:\(card.kind.rawValue)",
                rowIndex: 0,
                target: target,
                kind: kind
            )
        case .openAppSearch(let query):
            let original = lastUserMessageForCard.isEmpty
                ? (messages.reversed().first(where: { $0.role == .parent })?.content ?? "")
                : lastUserMessageForCard
            activeAppStoreSearchRequest = AppStoreSearchRequest(
                query: query,
                targetDisplay: card.targetDisplay,
                originalMessage: original
            )
        case .renameList(let target):
            // No chat endpoint renames a list — guide the parent to the kid
            // device's Lock-setup, where list names live.
            messages.append(ChatMessage(
                role: .agent,
                content: "“\(target)” clashes with a built-in category name. Rename that Saved List on the kid device (Settings → Evlin → Lock setup), then ask me again.",
                timestamp: Date()
            ))
        case .none:
            break
        }
    }

    @MainActor
    func cancelAppStoreSearch() {
        activeAppStoreSearchRequest = nil
    }

    @MainActor
    func handleAppStoreSearchSelection(
        result: CatalogSearchResultDTO,
        request: AppStoreSearchRequest
    ) {
        guard let bundleID = result.bundleID, !bundleID.isEmpty else {
            messages.append(ChatMessage(
                role: .agent,
                content: "I couldn't use that result because it has no bundle id.",
                timestamp: Date()
            ))
            return
        }
        guard let familyID = currentFamilyAndChildIDs().familyID else {
            messages.append(ChatMessage(
                role: .agent,
                content: "I couldn't save that app choice because this phone is not paired to a family yet.",
                timestamp: Date()
            ))
            return
        }

        activeAppStoreSearchRequest = nil
        isThinking = true
        let rewritten = AppControlRouter.rewriteOriginalCommand(
            request.originalMessage,
            replacing: request.targetDisplay,
            with: result.canonicalName
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.apiClient.confirmFamilyApp(FamilyAppConfirmation(
                    familyID: familyID,
                    canonicalName: result.canonicalName,
                    bundleID: bundleID,
                    artworkURL: result.artworkURL,
                    alias: request.targetDisplay,
                    source: "app_store_confirmed"
                ))
                await MainActor.run {
                    self.resendWithPhrase(rewritten)
                }
            } catch {
                await MainActor.run {
                    self.isThinking = false
                    self.messages.append(ChatMessage(
                        role: .agent,
                        content: "I couldn't save that app choice. Try again.",
                        timestamp: Date()
                    ))
                }
            }
        }
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
            showComingSoon(cardID, note: "Multi-child selection UI isn't fully wired yet — include the child's name in your message, e.g. \"lock \(childName)'s phone for 30 min\".")

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

        case .singleAppShieldAdvice, .shieldTokenMissing, .appStoreDisambiguation,
             .appNotFoundTerminal, .childDisambiguation, .categoryRenameRequired,
             .cannotBlockCategory, .categoryShieldOffer, .catalogAppInactive,
             .bundleIDRequired, .lockSelectedAppsConfirm, .lockSelectedAppsEmpty,
             .restrictionUnlockPicker:
            // Task 11/6 app-control cards are driven by currentAppControlCard +
            // handleAppControlOption / handleAppControlCandidate, NOT by the Brain
            // CardHandlers primary slot. This branch keeps the switch exhaustive;
            // it should never fire.
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

    private func resendWithPhrase(_ phrase: String, childDeviceIDOverride: UUID? = nil) {
        currentCard = nil
        messages.append(ChatMessage(role: .parent, content: phrase, timestamp: Date()))
        isThinking = true
        dispatchChat(
            userMessage: phrase,
            forceConfirmations: [],
            childDeviceIDOverride: childDeviceIDOverride
        )
    }

    func requestUnlock(_ target: ReceiptUnlockTarget) {
        resendWithPhrase(Self.receiptUnlockPhrase(for: target))
    }

    nonisolated static func receiptUnlockPhrase(for target: ReceiptUnlockTarget) -> String {
        let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "unshield \(name)"
    }

    /// Task 11 — "Block instead" on a receipt. Escalates the still-covered
    /// target to a permanent bundle-id block by re-dispatching `block <X>`
    /// through the existing chat pipeline (the same block route any "block X"
    /// message takes). Produces a fresh receipt; creates NO new Brain card.
    @MainActor
    func requestBlock(_ target: ReceiptUnlockTarget) {
        let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        resendWithPhrase("block \(name)")
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
            message.receiptState = .confirmedExact(
                verb: verb,
                displayName: displayName,
                unlocksAt: nil,
                artworkURL: nil
            )
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
            return .failedOther(reason: Self.parentFacingExecutionFailure(message))
        case .limitQuotaExceeded(let windows, let slotsNeeded, let cap):
            // TODO(P6): dedicated limit-quota receipt copy. P3 routes it through
            // the generic failure surface so the switch stays exhaustive.
            return .failedOther(
                reason: "Time limit needs \(slotsNeeded) schedule slot(s) "
                    + "(\(windows) window(s)) but only \(cap) are available."
            )
        }
    }

    nonisolated static func parentFacingExecutionFailure(_ rawValue: String) -> String {
        switch rawValue {
        case "lock_store_unavailable":
            return "Screen Time controls weren't available on the selected kid device. Open Evlin there, then try again."
        case "stale_identity":
            return "That device changed while the command was applying. Try again."
        default:
            return "The kid device couldn't apply this command. Try again."
        }
    }

    // MARK: - Ack-status polling (P1-1 fix)

    /// Re-arm ack polling for any receipt still stuck in a non-confirmed "we
    /// gave up waiting" state (`.pending` / `.pickedUp` / `.kidNotResponding`).
    ///
    /// The kid frequently acks LATE — e.g. it was backgrounded and only finished
    /// the ack on its next foreground poll, minutes after `startAckPoll`'s 90s
    /// deadline. The original poll has long since ended, so without this the
    /// receipt card spins forever even though the backend is already
    /// `confirmed`. Called when chat (re)appears and on push / state-invalidation
    /// wakes; an already-acked command resolves on the first 2s tick.
    func reconcilePendingReceipts() {
        for message in messages {
            guard let commandID = message.commandID,
                  let state = message.receiptState else { continue }
            switch state {
            case .pending, .pickedUp, .kidNotResponding:
                activePolls[commandID]?.cancel()
                startAckPoll(
                    commandID: commandID,
                    messageID: message.id,
                    targetDisplay: nil,
                    expiresAt: nil
                )
            default:
                break
            }
        }
    }

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
            var sawKidPickup = false
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
                print("[AckPoll] tick=\(tickCount) cmd=\(commandID) status=\(resp.status) delivery=\(resp.deliveryState ?? "nil")")

                let done = await MainActor.run { () -> Bool in
                    switch resp.status {
                    case "pending", "queued", "in_flight":
                        switch resp.deliveryState {
                        case "picked_up":
                            sawKidPickup = true
                            self.applyReceipt(.pickedUp, effective: nil, messageID: messageID)
                        case "delayed":
                            self.applyReceipt(.kidNotResponding, effective: nil, messageID: messageID)
                            return true
                        default:
                            break
                        }
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
                            .confirmedExact(
                                verb: verb,
                                displayName: name,
                                unlocksAt: actualUnlocksAt,
                                artworkURL: resp.artworkURL
                            ),
                            effective: resp.effectiveState,
                            messageID: messageID,
                            // Prefer the ACTUALLY-APPLIED shield tier (kid-reported) over
                            // resp.target_type — the latter is sometimes the "app" fallback
                            // even for a category, which let "Social" render a by-name iTunes
                            // artwork (a random social app's icon). Match the covering shield
                            // by display name ONLY: on an UNSHIELD the just-removed target is
                            // no longer in `shieldsCovering`, so a `.first` fallback would pick
                            // an unrelated leftover shield (e.g. a still-locked app). No match →
                            // fall through to resp.target_type.
                            targetKind: Self.receiptTargetKind(
                                fromShieldTier: resp.effectiveState?.shieldsCovering
                                    .first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame })?.tier
                            ) ?? Self.receiptTargetKind(from: resp.targetType)
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
                self?.applyReceipt(sawKidPickup ? .pickedUp : .kidNotResponding, effective: nil, messageID: messageID)
                print("[AckPoll] applyReceipt done cmd=\(commandID)")
            }
        }
        activePolls[commandID] = task
    }

    @MainActor
    private func applyReceipt(
        _ state: ReceiptState,
        effective: AckEffectiveState?,
        messageID: UUID,
        targetKind: NameIconKind? = nil
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].receiptState = state
        messages[idx].receiptEffectiveState = effective
        if let targetKind {
            messages[idx].receiptTargetKind = targetKind
        }
    }

    /// Map the backend ack `target_type` to the receipt icon kind.
    static func receiptTargetKind(from targetType: String?) -> NameIconKind {
        switch targetType?.lowercased() {
        case "category": return .category
        case "list":     return .savedList
        case "all":      return .all
        default:         return .app
        }
    }

    /// Map the ACTUALLY-APPLIED shield's `tier` (kid-reported, authoritative) to the
    /// receipt icon kind. Preferred over `resp.target_type`, which the backend
    /// sometimes leaves as the "app" fallback even for a category — that let a
    /// category receipt (e.g. "Social") render a by-name iTunes artwork (Snapchat).
    /// `ShieldTier` raw values: exactApp / savedList / category / allApps / all.
    static func receiptTargetKind(fromShieldTier tier: String?) -> NameIconKind? {
        switch tier {
        case "category":            return .category
        case "savedList":           return .savedList
        case "allApps", "all":      return .all
        case "exactApp":            return .app
        default:                    return nil
        }
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

    /// Pure transform for the exec-receipt attach so it's unit-testable.
    /// Fallback rule (audit finding #3): an executed receipt must NEVER be
    /// dropped — if no agent bubble exists to host it, append a fresh one.
    nonisolated static func attachingExecReceipt(
        _ receipt: ReceiptDTO,
        proposalToken: String,
        to messages: [ChatMessage]
    ) -> [ChatMessage] {
        var out = messages
        if let i = out.lastIndex(where: { $0.role == .agent }) {
            var msg = out[i]
            msg.proposals?.removeAll(where: { $0.token == proposalToken })
            msg.receipts = (msg.receipts ?? []) + [receipt]
            out[i] = msg
            return out
        }
        var msg = ChatMessage(
            role: .agent,
            content: receipt.summary,
            timestamp: Date(),
            reasoning: nil,
            action: nil
        )
        msg.receipts = [receipt]
        out.append(msg)
        return out
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
                case .followUpAppControlCard(let next):
                    self.pendingPlanArchCard = nil
                    self.currentAppControlCard = next
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
                messages = Self.attachingExecReceipt(
                    receipt, proposalToken: p.token, to: messages)
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

        // The endpoint requires `child_id` (the kid's device id, same source as
        // tickReflectionSubmissionPoll). Without it the backend 422s every poll.
        guard let childRaw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
              let childUUID = UUID(uuidString: childRaw)
        else { return }

        let url = URL(string: "\(rawBase)/parent/reflection/pending-events?child_id=\(childUUID.uuidString)")!
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

    /// Shared request-body builder for BOTH the JSON path
    /// (`sendChatMessageWithRawData`) and the streaming path
    /// (`dispatchChatStreaming`) — they must send byte-identical bodies.
    /// `history` is recomputed from `messages` at call time (spec §3.2:
    /// excludes the seed message, last 10 turns).
    private func makeChatRequestBody(
        userMessage: String,
        forceConfirmations: [String],
        skipFastpath: Bool,
        childDeviceIDOverride: UUID? = nil
    ) throws -> Data {
        let history: [[String: String]] = messages.filter { !$0.isSeed }.suffix(10).map { msg in
            ["role": msg.role == .parent ? "parent" : "agent", "content": msg.content]
        }
        let familyID = UserDefaults.standard.string(forKey: "evlin.familyID")
        let storedChildID = UserDefaults.standard.string(forKey: "evlin.childDeviceID")
        // Multi-device gate: a cached device id is context, not an explicit
        // target choice for this chat turn.
        let cdid = childDeviceIDOverride?.uuidString ?? Self.effectiveChildDeviceID(
            deviceCount: childDeviceCountProvider(),
            storedChildDeviceID: (storedChildID?.isEmpty == false) ? storedChildID : nil
        )

        let bodyObj = APIClient.ChatRequest(
            message: userMessage,
            child_name: childName,
            history: history,
            family_id: familyID,
            force_confirmations: forceConfirmations,
            child_device_id: cdid,
            client_alias_state: currentClientAliasStateCodable(),
            skip_fastpath: skipFastpath,
            conversation_id: currentConversationID.uuidString
        )
        return try JSONEncoder().encode(bodyObj)
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
        skipFastpath: Bool = false,
        childDeviceIDOverride: UUID? = nil
    ) async throws -> (APIClient.ChatResponse, Data, String?) {
        let encodedBody = try makeChatRequestBody(
            userMessage: message,
            forceConfirmations: forceConfirmations,
            skipFastpath: skipFastpath,
            childDeviceIDOverride: childDeviceIDOverride
        )

        // B4: route through authedRequest/authedData (Bearer + single-flight 401 refresh).
        // The outer retry loop handles transient 5xx; authedData handles 401 internally.
        var lastStatus = 0
        for attempt in 0..<3 {
            var request = apiClient.authedRequest(path: "/parent/chat", method: "POST")
            request.timeoutInterval = 30
            request.httpBody = encodedBody

            do {
                let (data, http) = try await apiClient.authedData(for: request)
                lastStatus = http.statusCode

                if lastStatus == 200 {
                    let decoded = try JSONDecoder().decode(APIClient.ChatResponse.self, from: data)
                    let turnID = http.value(forHTTPHeaderField: "X-Brain-Turn-Id")
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
    func tryHandlePlanArchCard(
        from data: Data,
        message: String? = nil,
        debugTurnID: String? = nil,
        reuseTextBubbleID: UUID? = nil,
        attachSafetyCard: Bool = false
    ) -> Bool {
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
        if appendOrReuseAgentTextBubble(
            reuseTextBubbleID: reuseTextBubbleID,
            text: trimmedMessage,
            debugTurnID: debugTurnID,
            attachSafetyCard: attachSafetyCard
        ) {
            return true
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
    ///   .event → dismissEventCard (event.*/target.* self-render+act via EventTargetCardView)
    ///   .query → handleQueryCardStub (2D placeholder)
    func handlePlanArchOption(_ opt: PlanArchCardOption) {
        guard let card = self.pendingPlanArchCard else { return }
        switch card.source {
        case .plan:
            submitPlanArchPatch(card: card, option: opt)
        case .event:
            // event.*/target.* now self-render + act via EventTargetCardView; the
            // generic PlanArchCardView option path no longer drives them.
            dismissEventCard()
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
                case .followUpAppControlCard(let next):
                    self.pendingPlanArchCard = nil
                    self.currentAppControlCard = next
                case .rejected(let message), .expired(let message):
                    self.messages.append(ChatMessage(role: .agent, content: message, timestamp: Date()))
                case .error(let err):
                    self.messages.append(ChatMessage(role: .agent, content: "Error: \(err.localizedDescription)", timestamp: Date()))
                }
            }
        }
    }

    // MARK: - P5 calendar-in-chat: event.* / target.* card handlers

    private func agentClient() -> AgentClient { AgentClient(baseURL: apiClient.baseURL) }

    @MainActor func dismissEventCard() {
        pendingPlanArchCard = nil
        advancePlanArchCardQueue()
    }

    /// Apply a continuation endpoint's response (event-select / resolve-target /
    /// event-scope). A staged follow-up card (e.g. a concrete event.create_confirm)
    /// is the SUCCESSOR of the card the user just acted on, so it REPLACES the
    /// front of the queue rather than just overwriting the head pointer. That
    /// keeps the invariant pendingPlanArchCard === pendingPlanArchCardQueue.first,
    /// so a sibling card queued behind it on a compound turn isn't stranded by a
    /// later advancePlanArchCardQueue() popping a stale front (finding #8). No
    /// follow-up → pop the front and advance to the next queued card.
    @MainActor func applyAgentResult(_ result: AgentClient.AgentCardResponse) {
        if let next = result.card_payloads?.first {
            if pendingPlanArchCardQueue.isEmpty {
                pendingPlanArchCardQueue = [next]
            } else {
                pendingPlanArchCardQueue[0] = next
            }
            pendingPlanArchCard = next
        } else {
            pendingPlanArchCard = nil
            advancePlanArchCardQueue()
        }
    }

    /// Returns nil on success so the card shows "✓ Added" IN PLACE — no dismiss,
    /// no new card (finding D). Returns a user-visible error string on failure.
    /// expired → clear + notice; other errors stay inline on the card.
    func handleEventConfirm(_ token: String) async -> String? {
        do {
            _ = try await agentClient().eventExec(token: token)
            NotificationCenter.default.post(name: .evlinCalendarInvalidated, object: nil)
            // The "✓ Added" state lives in the card view's @State, which dies
            // if the view is rebuilt (tab switch). Record the consumed token so
            // the rebuilt card renders confirmed instead of re-offering Confirm
            // (a second tap would 410 — the token is single-use).
            confirmedEventTokens.insert(token)
            return nil
        } catch AgentClient.AgentTargetError.expired {
            await expireEventCard()
            return "This calendar action expired. Try again."
        } catch let error as LocalizedError {
            return error.errorDescription ?? "Couldn't save — try again."
        } catch {
            return error.localizedDescription
        }
    }

    func handleEventSelect(_ ct: String, _ eventId: String, _ occ: String) async {
        do { let r = try await agentClient().eventSelect(
                continuationToken: ct, eventId: eventId,
                occurrenceStart: occ, continuationAction: "")
             await MainActor.run { applyAgentResult(r) } }
        catch AgentClient.AgentTargetError.expired { await expireEventCard() }
        catch { await MainActor.run { self.errorMessage = "Couldn't continue — try again." } }
    }

    func handleResolveTarget(_ ct: String, _ ids: [String]) async {
        do {
            let result = try await agentClient().resolveTarget(
                continuationToken: ct,
                selectedIds: ids
            )
            await MainActor.run {
                if let resume = result.resume_chat,
                   let deviceID = UUID(uuidString: resume.child_device_id) {
                    pendingPlanArchCard = nil
                    advancePlanArchCardQueue()
                    isThinking = true
                    dispatchChat(
                        userMessage: resume.message,
                        forceConfirmations: [],
                        childDeviceIDOverride: deviceID
                    )
                } else {
                    applyAgentResult(result)
                }
            }
        }
        catch AgentClient.AgentTargetError.expired { await expireEventCard() }
        catch { await MainActor.run { self.errorMessage = "Couldn't continue — try again." } }
    }

    /// One shared answer for a multi-device batch. The reply is another card —
    /// the next question, or the per-device receipt — so it goes through the
    /// same `applyAgentResult` path and keeps the pending-card queue invariant
    /// that `handleResolveTarget` relies on.
    func handleAppControlBatch(
        _ ct: String,
        _ choice: String?,
        _ duration: AgentClient.AppControlBatchDuration?
    ) async {
        do {
            let result = try await agentClient().appControlBatch(
                continuationToken: ct, choice: choice, duration: duration)
            await MainActor.run { applyAgentResult(result) }
        }
        catch AgentClient.AgentTargetError.expired { await expireEventCard() }
        catch { await MainActor.run { self.errorMessage = "Couldn't continue — try again." } }
    }

    func handleEventScope(_ ct: String) async {
        do { let r = try await agentClient().eventScope(continuationToken: ct, scope: "series")
             await MainActor.run { applyAgentResult(r) } }
        catch AgentClient.AgentTargetError.expired { await expireEventCard() }
        catch { await MainActor.run { self.errorMessage = "Couldn't continue — try again." } }
    }

    @MainActor private func expireEventCard() {
        pendingPlanArchCard = nil
        errorMessage = "That expired — just ask again."
        advancePlanArchCardQueue()
    }

    /// event.reflection_review_pending — Approve/Redo now ACT (spec §11). Reuses
    /// the two SEPARATE existing endpoints: approve → /approve {parent_note};
    /// redo → /request-redo {redo_note}. `rid` comes from detail["rid"]
    /// (bigkid_parent.py emits rid/summary/essay_excerpt).
    func handleReflectionReview(_ card: PlanArchCardPayload, approve: Bool, note: String) async {
        let detail = EventTargetDetail(card.detail)
        guard let ridStr = detail.string("rid"), let rid = UUID(uuidString: ridStr) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if approve {
                try await apiClient.approveChildReflectionSubmission(
                    reflectionId: rid, parentNote: trimmed.isEmpty ? nil : trimmed)
            } else {
                try await apiClient.requestRedoChildReflection(
                    reflectionId: rid, redoNote: trimmed.isEmpty ? nil : trimmed)
            }
            await MainActor.run { dismissEventCard() }
        } catch {
            await MainActor.run { self.errorMessage = "Couldn't submit — try again." }
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
            let selectedLabel = current.title.localizedCaseInsensitiveContains("unblock")
                || current.options.contains { $0.label.localizedCaseInsensitiveContains("unblock") }
                ? "Unblock selected"
                : "Unlock selected"
            let synthesised = PlanArchCardOption(
                label: selectedLabel,
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
