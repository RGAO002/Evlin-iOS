import SwiftUI

struct ChatView: View {
    @EnvironmentObject var apiClient: APIClient
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @StateObject private var viewModel = ChatViewModel()
    var isPreview = false
    var activeChild: ChildProfile? = nil

    /// Map `viewModel.childName` back to a `ChildProfile.id` so we can
    /// clear / reset the parent-side reflection fixture store when the
    /// parent approves or requests a redo from the chat card. The chat
    /// surface deals in child *names* (display strings) — Home/Profile
    /// deal in child *ids*.
    private var matchedChildId: String? {
        ChildProfile.all.first { $0.name == viewModel.childName }?.id
    }


    var body: some View {
        VStack(spacing: 0) {
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
                                    ChatBubble(content: message.content, role: message.role, timestamp: message.timestamp)
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
                                    ReceiptCard(state: receipt, effectiveState: message.receiptEffectiveState)
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
                                        resolved: reflection.resolved,
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
                                        onRedo: {
                                            // Prototype: "Write again"
                                            // sends the kid back to the
                                            // writing step. Flip the
                                            // fixture summary to pending
                                            // so Home/Profile show the
                                            // assigned state again.
                                            // TODO: wire to backend
                                            // reflection redo endpoint
                                            // when available.
                                            if let childId = matchedChildId {
                                                reflectionStore.resetToPending(childId: childId)
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
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, 160)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let last = viewModel.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Quick prompts + Input bar
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
            .background(Color.evSurfaceContainer)
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
