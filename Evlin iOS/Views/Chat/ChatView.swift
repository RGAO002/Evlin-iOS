import SwiftUI

struct ChatView: View {
    @EnvironmentObject var apiClient: APIClient
    @StateObject private var viewModel = ChatViewModel()
    var isPreview = false
    var activeChild: ChildProfile? = nil


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
                                        }
                                    )
                                }
                            }
                            .id(message.id)
                        }

                        if viewModel.isThinking {
                            thinkingIndicator
                        }

                        // Confirmation card (Phase 9) — rendered below the message list.
                        if let (cardID, context, handlers) = viewModel.currentCard {
                            CardDispatcher(cardID: cardID, context: context, handlers: handlers)
                                .padding(.top, Spacing.md)
                                .transition(.opacity.combined(with: .scale))
                        }

                        // Plan-arch card (AGENT_PLAN_ARCH=1) — typed CardPayload
                        // from the new orchestrator. Rendered via PlanArchCardView
                        // with option taps wired to PlanPatchClient.
                        if let planArchCard = viewModel.pendingPlanArchCard {
                            PlanArchCardView(
                                card: planArchCard,
                                onOption: { opt in viewModel.handlePlanArchOption(opt) },
                                onLazyTag: { card in viewModel.handlePlanArchLazyTag(for: card) }
                            )
                            .padding(.top, Spacing.md)
                            .transition(.opacity.combined(with: .scale))
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
        }
        .onDisappear {
            guard !isPreview else { return }
            viewModel.stopReflectionSubmissionPolling()
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

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.evOutlineVariant)
                        .frame(width: 5, height: 5)
                }
            }
            .opacity(0.8)

            Spacer()
        }
        .padding(.vertical, Spacing.md)
    }
}

#Preview {
    ChatView(isPreview: true)
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
}
