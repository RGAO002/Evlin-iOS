import SwiftUI

struct ChatView: View {
    @EnvironmentObject var apiClient: APIClient
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @StateObject private var viewModel = ChatViewModel()
    @State private var keyboardOverlapHeight: CGFloat = 0
    var isPreview = false
    var activeChild: ChildProfile? = nil
    private let bottomAnchorID = "chat-bottom-anchor"

    /// Map `viewModel.childName` back to a `ChildProfile.id` so we can
    /// clear / reset the parent-side reflection fixture store when the
    /// parent approves or requests a redo from the chat card. The chat
    /// surface deals in child *names* (display strings) — Home/Profile
    /// deal in child *ids*.
    private var matchedChildId: String? {
        ChildProfile.all.first { $0.name == viewModel.childName }?.id
    }


    var body: some View {
        GeometryReader { geometry in
            content
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    let update = keyboardUpdate(from: notification, viewFrame: geometry.frame(in: .global))
                    let timing = Self.keyboardLiftTiming(
                        keyboardOverlap: update.overlap,
                        tabInset: EvlinTabBar.visibleHeight,
                        duration: update.duration
                    )
                    withAnimation(
                        Self.keyboardAnimation(duration: timing.activeDuration, curveRawValue: update.curveRawValue)
                            .delay(timing.delay)
                    ) {
                        keyboardOverlapHeight = update.overlap
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                    let update = keyboardUpdate(from: notification, viewFrame: geometry.frame(in: .global))
                    let timing = Self.keyboardDropTiming(
                        currentKeyboardOverlap: keyboardOverlapHeight,
                        tabInset: EvlinTabBar.visibleHeight,
                        duration: update.duration
                    )
                    withAnimation(
                        Self.keyboardAnimation(duration: timing.activeDuration, curveRawValue: update.curveRawValue)
                            .delay(timing.delay)
                    ) {
                        keyboardOverlapHeight = 0
                    }
                }
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Spacing.xxxl) {
                        editorialHeader

                        ForEach(viewModel.messages) { message in
                            VStack(alignment: message.role == .parent ? .trailing : .leading, spacing: Spacing.xl) {
                                // Lock confirmation card
                                if let mins = message.lockMinutes, let name = message.lockChildName {
                                    LockConfirmationCard(minutes: mins, childName: name)
                                }

                                // Strategy artifact card (Task 20)
                                if message.isStrategyArtifact, message.role == .agent {
                                    StrategyCard(data: StrategyCardData(
                                        title: message.strategyTitle ?? "",
                                        status: message.strategyStatus ?? "",
                                        category: message.strategyCategory ?? "",
                                        videoLabel: message.strategyVideoLabel ?? "",
                                        videoDuration: message.strategyVideoDuration ?? "",
                                        tip: message.strategyTip ?? "",
                                        videoId: message.videoId,
                                        videoThumbnail: message.videoThumbnail
                                    ))
                                }

                                // Chat bubble (skip for strategy-only messages with empty content)
                                if !message.content.isEmpty {
                                    ChatBubble(
                                        content: message.content,
                                        role: message.role,
                                        timestamp: message.timestamp,
                                        debugTurnID: message.debugTurnID
                                    )
                                }

                                // Safety status card + follow-up
                                if message.isSafetyCard == true {
                                    SafetyStatusCard(childName: viewModel.childName)
                                    SafetyActionButtons()
                                }

                                // Video recommendation card
                                if let title = message.videoTitle, let thumb = message.videoThumbnail, let vid = message.videoId {
                                    VideoRecommendationCard(
                                        video: RecommendedVideo(
                                            title: title,
                                            description: message.videoDescription ?? "",
                                            thumbnail: thumb,
                                            videoId: vid
                                        )
                                    )
                                }

                                // Receipt card — shows pending spinner then flips
                                // to success/failure + honest effective-state line
                                // when the child acks. See plan Phase 8.
                                if message.role == .agent, let receipt = message.receiptState {
                                    ReceiptCard(
                                        state: receipt,
                                        effectiveState: message.receiptEffectiveState,
                                        onRequestUnlock: { target in
                                            viewModel.requestUnlock(target)
                                        },
                                        onRequestBlock: { target in
                                            viewModel.requestBlock(target)
                                        }
                                    )
                                }

                                // Agent envelope (Phase E) — staged proposals
                                // for parent confirmation, and executed receipts
                                // with 60s Undo countdown. Empty arrays render
                                // nothing.
                                if message.role == .agent,
                                   let proposals = message.proposals, !proposals.isEmpty {
                                    VStack(spacing: 10) {
                                        ForEach(proposals, id: \.token) { p in
                                            ProposalCard(
                                                proposal: p,
                                                onConfirm: { await viewModel.confirmProposal(p) },
                                                onSkip: { viewModel.skipProposal(p) },
                                                rowAliasMissTargets: viewModel.rowAliasMissTargets(for: p),
                                                onTagRow: { idx in viewModel.beginLazyTag(for: p, rowIndex: idx) }
                                            )
                                        }
                                    }
                                }
                                if message.role == .agent,
                                   let receipts = message.receipts, !receipts.isEmpty {
                                    VStack(spacing: 8) {
                                        ForEach(receipts, id: \.summary) { r in
                                            ReceiptBubble(receipt: r, onUndo: { token in
                                                await viewModel.undoReceipt(token: token)
                                            })
                                        }
                                    }
                                }

                                // BigKid: reflection essay submitted → parent approves in-chat
                                if message.role == .agent,
                                   let reflection = message.reflectionSubmissionReview {
                                    ReflectionSubmissionReviewCard(
                                        childName: viewModel.childName,
                                        writingPrompt: reflection.writingPrompt,
                                        essayText: reflection.essayText,
                                        submittedAt: reflection.submittedAt,
                                        topicLabel: reflection.topicLabel,
                                        stepsCompleted: reflection.stepsCompleted,
                                        status: reflection.status,
                                        onApprove: { note in
                                            await viewModel.approveReflectionSubmissionFromChat(
                                                messageId: message.id,
                                                reflectionId: reflection.reflectionId,
                                                parentNoteTrimmed: note
                                            )
                                            // Parent approved → the
                                            // reflection is done. Clear
                                            // the home/profile under-
                                            // reflection card right
                                            // away. (Backend poll will
                                            // eventually agree, but the
                                            // UI shouldn't have to wait
                                            // for it.)
                                            if let childId = matchedChildId {
                                                reflectionStore.clear(childId: childId)
                                            }
                                        },
                                        onRedo: { typedNote in
                                            // "Write again" routes through the SAME
                                            // backend path as the Step-3 "Request
                                            // redo" button. The card forwards the
                                            // parent's typed message (already
                                            // trimmed); the VM substitutes the
                                            // default coaching string only when
                                            // it's empty.
                                            let effectiveNote = typedNote.isEmpty
                                                ? ReflectionParentNoteFallback.redoTakeAnotherLook
                                                : typedNote
                                            await viewModel.requestRedoReflectionFromChat(
                                                messageId: message.id,
                                                reflectionId: reflection.reflectionId,
                                                parentNoteTrimmed: typedNote
                                            )
                                            if let childId = matchedChildId {
                                                reflectionStore.applyParentRedoLocally(
                                                    childId: childId,
                                                    redoNote: effectiveNote
                                                )
                                            }
                                        }
                                    )
                                }

                                // Strategy-agent T11.12 — 👍/👎 feedback row under each
                                // agent bubble that has visible content.
                                if message.role == .agent, !message.content.isEmpty {
                                    AssistantFeedbackButtons(messageId: message.id.uuidString) { rating in
                                        Task {
                                            await viewModel.sendFeedback(
                                                messageId: message.id.uuidString,
                                                rating: rating
                                            )
                                        }
                                    }
                                }
                            }
                            .id(message.id)
                        }

                        if viewModel.isThinking {
                            thinkingIndicator
                        }

                        // Confirmation card (Phase 9) — rendered below the message list.
                        if let (cardID, context, handlers) = viewModel.currentCard {
                            VStack(spacing: Spacing.sm) {
                                CardDispatcher(cardID: cardID, context: context, handlers: handlers)
                                reinterpretButton
                            }
                            .padding(.top, Spacing.md)
                            .transition(.opacity.combined(with: .scale))
                        }

                        // Task 11 — deterministic app-control card (single_app_shield_advice,
                        // shield_token_missing, disambiguation, …). Rendered SEPARATELY from
                        // the Brain card path above; buttons re-dispatch via force_confirmations
                        // or open the lazy-tag picker / dictionary flows.
                        if let appControlCard = viewModel.currentAppControlCard {
                            VStack(spacing: Spacing.sm) {
                                AppControlCard(
                                    model: appControlCard,
                                    onOption: { option in viewModel.handleAppControlOption(option) },
                                    onCandidate: { candidate in viewModel.handleAppControlCandidate(candidate) },
                                    onCancel: { viewModel.dismissAppControlCard() }
                                )
                                reinterpretButton
                            }
                            .padding(.top, Spacing.md)
                            .transition(.opacity.combined(with: .scale))
                        }

                        // Plan-arch card (AGENT_PLAN_ARCH=1) — typed CardPayload
                        // from the new orchestrator. Phase 2A dispatches through
                        // PlanArchCardAdapter → CardDispatcher (polished cards).
                        // Falls back to PlanArchCardView for unknown / future kinds.
                        if let planArchCard = viewModel.pendingPlanArchCard {
                            // Strategy-agent T11.12 — question.<style> card path.
                            if let qcard = QuestionCardAdapter.parse(planArchCard) {
                                VStack(spacing: Spacing.sm) {
                                    QuestionCardView(
                                        card: qcard,
                                        onAnswer: { body in
                                            Task { await viewModel.sendAnswer(body) }
                                        },
                                        onCancel: {
                                            viewModel.pendingPlanArchCard = nil
                                        }
                                    )
                                    reinterpretButton
                                }
                                .padding(.top, Spacing.md)
                                .transition(.opacity.combined(with: .scale))
                            } else if let renderModel = PlanArchCardAdapter.adapt(
                                planArchCard, childName: viewModel.childName
                            ) {
                                // Phase 2A: dispatch through the adapter back onto polished cards.
                                VStack(spacing: Spacing.sm) {
                                    CardDispatcher(
                                        cardID: renderModel.cardID,
                                        context: renderModel.context,
                                        handlers: viewModel.makePlanArchHandlers(for: planArchCard)
                                    )
                                    reinterpretButton
                                }
                                .padding(.top, Spacing.md)
                                .transition(.opacity.combined(with: .scale))
                            } else {
                                // Unknown kind — debug fallback only. Spec §1 acceptance requires
                                // every known kind to go through the adapter.
                                VStack(spacing: Spacing.sm) {
                                    PlanArchCardView(
                                        card: planArchCard,
                                        onOption: { opt in viewModel.handlePlanArchOption(opt) },
                                        onLazyTag: { card in viewModel.handlePlanArchLazyTag(for: card) }
                                    )
                                    reinterpretButton
                                }
                                .padding(.top, Spacing.md)
                                .transition(.opacity.combined(with: .scale))
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Self.messageListBottomPadding())
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: viewModel.pendingPlanArchCard?.planToken) { _, _ in
                    withAnimation { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: viewModel.currentCard?.0.rawValue) { _, _ in
                    withAnimation { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                }
                .onChange(of: viewModel.currentAppControlCard?.kind) { _, _ in
                    withAnimation { proxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                }
            }

            composerPanel
                .background(Color.evSurfaceContainer)
                .padding(.bottom, Self.composerBottomInset(keyboardOverlap: keyboardOverlapHeight))
        }
        .background(Color.evSurfaceContainerLow)
        .onAppear {
            if !isPreview {
                viewModel.apiClient = apiClient
            }
            if let active = activeChild {
                viewModel.childName = active.name
            }
            guard !isPreview else { return }
            viewModel.startReflectionSubmissionPolling()
            Task { await viewModel.tickReflectionSubmissionPoll() }
            viewModel.startReflectionEventPolling()
        }
        .onDisappear {
            guard !isPreview else { return }
            viewModel.stopReflectionSubmissionPolling()
            viewModel.stopReflectionEventPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
            guard !isPreview else { return }
            Task { await viewModel.tickReflectionSubmissionPoll() }
        }
        .sheet(item: $viewModel.activeLazyTagRequest) { req in
            CustomTokenPickerView(
                request: req,
                onSelect: { token, request in
                    viewModel.handleTagSelection(token: token, request: request)
                },
                onCancel: {
                    viewModel.cancelLazyTag()
                }
            )
        }
        .sheet(item: $viewModel.activeAppStoreSearchRequest) { req in
            AppStoreSearchPickerView(
                request: req,
                onSelect: { result, request in
                    viewModel.handleAppStoreSearchSelection(result: result, request: request)
                },
                onCancel: {
                    viewModel.cancelAppStoreSearch()
                }
            )
        }
    }

    private var composerPanel: some View {
        // Quick prompts + Input bar. This panel's background must wrap only
        // the visible controls; bottom lift is applied outside this view so it
        // cannot create a blank white spacer below the input.
        VStack(spacing: Spacing.lg) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(viewModel.quickPrompts, id: \.text) { prompt in
                        QuickPromptChip(icon: prompt.icon, text: prompt.text) {
                            viewModel.sendQuickPrompt(prompt)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }

            ChatInputBar(text: $viewModel.inputText) {
                viewModel.sendMessage()
            }
        }
        .padding(.top, Spacing.md)
    }

    static func composerBottomInset(
        keyboardOverlap: CGFloat,
        tabInset: CGFloat = EvlinTabBar.visibleHeight
    ) -> CGFloat {
        max(tabInset, keyboardOverlap)
    }

    static func messageListBottomPadding(
        composerPanelHeight: CGFloat = 148,
        tabInset: CGFloat = EvlinTabBar.visibleHeight,
        extraClearance: CGFloat = 28
    ) -> CGFloat {
        composerPanelHeight + tabInset + extraClearance
    }

    static func keyboardOverlap(keyboardFrameEnd: CGRect, viewFrame: CGRect) -> CGFloat {
        max(0, viewFrame.maxY - keyboardFrameEnd.minY)
    }

    static func keyboardLiftDelay(keyboardOverlap: CGFloat, tabInset: CGFloat, duration: Double) -> Double {
        keyboardLiftTiming(keyboardOverlap: keyboardOverlap, tabInset: tabInset, duration: duration).delay
    }

    static func keyboardLiftTiming(
        keyboardOverlap: CGFloat,
        tabInset: CGFloat,
        duration: Double
    ) -> (delay: Double, activeDuration: Double) {
        guard keyboardOverlap > tabInset, duration > 0 else { return (delay: 0, activeDuration: 0.01) }
        let delay = duration * Double(tabInset / keyboardOverlap)
        return (delay: delay, activeDuration: max(0.01, duration - delay))
    }

    static func keyboardDropTiming(
        currentKeyboardOverlap: CGFloat,
        tabInset: CGFloat,
        duration: Double
    ) -> (delay: Double, activeDuration: Double) {
        guard currentKeyboardOverlap > tabInset, duration > 0 else { return (delay: 0, activeDuration: 0.01) }
        let activeDuration = duration * Double((currentKeyboardOverlap - tabInset) / currentKeyboardOverlap)
        return (delay: 0, activeDuration: max(0.01, activeDuration))
    }

    static func keyboardAnimation(duration: Double, curveRawValue: UInt) -> Animation {
        let effectiveDuration = max(duration, 0.01)
        switch UIView.AnimationCurve(rawValue: Int(curveRawValue)) {
        case .easeIn:
            return .easeIn(duration: effectiveDuration)
        case .easeOut:
            return .easeOut(duration: effectiveDuration)
        case .linear:
            return .linear(duration: effectiveDuration)
        default:
            return .easeInOut(duration: effectiveDuration)
        }
    }

    private func keyboardUpdate(from notification: Notification, viewFrame: CGRect) -> (overlap: CGFloat, duration: Double, curveRawValue: UInt) {
        let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey]
        let curveRawValue: UInt
        if let rawCurve = rawCurve as? UInt {
            curveRawValue = rawCurve
        } else if let rawCurve = rawCurve as? Int {
            curveRawValue = UInt(rawCurve)
        } else {
            curveRawValue = UInt(UIView.AnimationCurve.easeInOut.rawValue)
        }
        return (
            overlap: Self.keyboardOverlap(keyboardFrameEnd: frame, viewFrame: viewFrame),
            duration: duration,
            curveRawValue: curveRawValue
        )
    }

    // MARK: - Editorial Header

    private var editorialHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVLIN AI")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text("Strategic Advisory")
                .font(.custom("Manrope", size: 26).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(Color.evPrimary)
            Text("Evlin is monitoring behavioral patterns across all profiles.")
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - "This isn't what I meant" escape hatch
    //
    // Shown ONLY below fastpath-emitted cards. Tapping resends the
    // parent's most recent user message with `skip_fastpath=true` so the
    // backend routes it through strategy_agent (the LLM) instead of the
    // deterministic fastpath router that produced the current card.
    //
    // Hidden entirely on AI-emitted cards. Re-tapping reinterpret there
    // would just send the same message back to the same LLM — useless.
    // Backend signals source via `ChatResponse.via_fastpath`; iOS mirrors
    // that into `viewModel.lastResponseViaFastpath`.
    //
    // Also gated on the presence of a parent-side message in history
    // (defensive — a card on screen should always imply one, but
    // empty-history rendering shouldn't fire reinterpret).
    @ViewBuilder
    private var reinterpretButton: some View {
        if viewModel.lastResponseViaFastpath {
            Button {
                viewModel.reinterpretWithAI()
            } label: {
                Text("This isn't what I meant")
                    .font(.evBodySmall)
                    .foregroundStyle(Color.evPrimary)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!viewModel.messages.contains(where: { $0.role == .parent }))
        }
    }

    // MARK: - Thinking Indicator

    private var thinkingIndicator: some View {
        HStack(spacing: Spacing.lg) {
            Circle()
                .fill(Color.evSurfaceContainerHighest)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.evPrimaryFixedDim)
                )

            TypingDots()

            Spacer()
        }
        .padding(.vertical, Spacing.md)
    }
}

/// Three dots that pulse in sequence — the standard "AI is thinking…" affordance.
///
/// Driven by TimelineView (not @State + repeatForever animations) so the loop
/// stays perfectly smooth regardless of view-tree churn, scroll updates, or
/// onAppear races. Each dot's scale + opacity are pure functions of clock
/// time minus a per-dot phase offset, so there's no animation to "restart"
/// when the view recomposes.
private struct TypingDots: View {
    /// Total loop length. 1.0s feels natural — slower than a heartbeat,
    /// faster than impatient.
    private let cycle: TimeInterval = 1.0
    /// Stagger between dot 1 / 2 / 3 — a third of the cycle apart so the
    /// pulse reads as a clean left-to-right wave.
    private let stagger: TimeInterval = 0.18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t - Double(i) * stagger).truncatingRemainder(dividingBy: cycle) / cycle
                    // Bell curve over [0,1]: peak at 0.5, valley at 0/1.
                    // sin(πx) is C¹-smooth so the pulse has no visible "snap".
                    let pulse = sin(phase * .pi)
                    let scale = 0.65 + 0.55 * pulse        // 0.65 → 1.2 → 0.65
                    let opacity = 0.45 + 0.45 * pulse      // 0.45 → 0.9 → 0.45
                    Circle()
                        .fill(Color.evOutlineVariant)
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }
            }
            // Reserve the maximum bounding height so the row doesn't jitter
            // vertically as dots scale past 1.0.
            .frame(height: 12)
        }
    }
}

#Preview {
    ChatView(isPreview: true)
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}
