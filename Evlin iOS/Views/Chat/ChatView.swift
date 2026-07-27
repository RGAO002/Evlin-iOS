import SwiftUI
import Combine

private final class ChatScrollController: ObservableObject {
    var onBottomDistanceChange: ((CGFloat) -> Void)?
    /// B6: called with the raw contentOffset.y on every scroll event.
    var onContentOffsetYChange: ((CGFloat) -> Void)?
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    func attach(to scrollView: UIScrollView?) {
        guard let scrollView else { return }
        if scrollView !== self.scrollView {
            self.scrollView = scrollView
            observations = [
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    self?.reportOnMain()
                },
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    self?.reportOnMain()
                },
                scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                    self?.reportOnMain()
                }
            ]
        }
        report()
    }

    func scrollToBottom(animated: Bool) {
        let delays = ChatView.scrollToBottomSettleDelays(animated: animated)
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                self.scrollToBottomOnce(
                    in: scrollView,
                    animated: animated && index == 0
                )
            }
        }
    }

    private func scrollToBottomOnce(in scrollView: UIScrollView, animated: Bool) {
        scrollView.layoutIfNeeded()
        let targetY = ChatView.scrollTargetOffsetY(
            contentSizeHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        )
        guard abs(targetY - scrollView.contentOffset.y) > 0.5 else { return }
        let previousKeyboardDismissMode = scrollView.keyboardDismissMode
        scrollView.keyboardDismissMode = .none
        let restoreKeyboardDismissMode = {
            scrollView.keyboardDismissMode = previousKeyboardDismissMode
        }
        if animated {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetY),
                    animated: false
                )
            } completion: { _ in
                restoreKeyboardDismissMode()
            }
        } else {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: false
            )
            restoreKeyboardDismissMode()
        }
    }

    private func reportOnMain() {
        DispatchQueue.main.async { [weak self] in
            self?.report()
        }
    }

    private func report() {
        guard let scrollView else { return }
        onBottomDistanceChange?(
            ChatView.scrollBottomDistance(
                contentOffsetY: scrollView.contentOffset.y,
                contentSizeHeight: scrollView.contentSize.height,
                viewportHeight: scrollView.bounds.height,
                adjustedBottomInset: scrollView.adjustedContentInset.bottom
            )
        )
        // B6: report raw Y for top-bar collapse direction tracking.
        onContentOffsetYChange?(scrollView.contentOffset.y)
    }
}

private struct ChatScrollMetricsObserver: UIViewRepresentable {
    @ObservedObject var controller: ChatScrollController
    let onBottomDistanceChange: (CGFloat) -> Void
    /// B6: optional raw content-offset callback for top-bar collapse.
    var onContentOffsetYChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ view: UIView, context: Context) {
        controller.onBottomDistanceChange = onBottomDistanceChange
        controller.onContentOffsetYChange = onContentOffsetYChange
        DispatchQueue.main.async {
            controller.attach(to: view.enclosingScrollView)
        }
    }

    final class Coordinator {}
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        if let scrollView = self as? UIScrollView {
            return scrollView
        }
        return superview?.enclosingScrollView
    }
}

struct ChatView: View {
    @EnvironmentObject var apiClient: APIClient
    @Environment(ParentReflectionFixtureStore.self) private var reflectionStore
    @Environment(FamilyStore.self) private var familyStore
    /// Injected by the shell (ContentView) so it outlives tab switches — the
    /// tab content is a `switch`, so this view is destroyed on every switch
    /// and a local @StateObject would drop pending confirm cards.
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var scrollController = ChatScrollController()
    @State private var keyboardOverlapHeight: CGFloat = 0
    @FocusState private var isComposerFocused: Bool
    var isPreview = false
    var activeChild: ChildProfile? = nil
    private let bottomAnchorID = "chat-bottom-anchor"
    /// How far the content bottom sits below the viewport (>0 means scrolled up).
    @State private var scrollBottomDistance: CGFloat = 0
    private var isAtBottom: Bool {
        !Self.shouldShowScrollToBottomButton(bottomDistance: scrollBottomDistance)
    }
    private var childAvatarURLsByID: [String: String] {
        Dictionary(
            familyStore.childProfiles.compactMap { child -> (String, String)? in
                guard let avatarURL = child.avatarURL, !avatarURL.isEmpty else {
                    return nil
                }
                return (child.id, avatarURL)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - B6: collapsing top bar state

    /// Whether the top bar is currently visible (hides on scroll-down, shows on scroll-up).
    @State private var barVisible: Bool = true
    /// Last recorded content offset Y from the scroll controller, used to detect direction.
    @State private var lastScrollOffsetY: CGFloat = 0
    /// Show the History sheet (B7 — sheet wired when ChatHistorySheet exists).
    @State private var showHistorySheet: Bool = false
    /// Rename alert presentation flag.
    @State private var showRenameAlert: Bool = false
    /// Rename alert text field binding.
    @State private var renameAlertText: String = ""

    /// Map `viewModel.childName` back to a `ChildProfile.id` so we can
    /// clear / reset the parent-side reflection fixture store when the
    /// parent approves or requests a redo from the chat card. The chat
    /// surface deals in child *names* (display strings) — Home/Profile
    /// deal in child *ids*.
    private var matchedChildId: String? {
        familyStore.childProfiles.first { $0.name == viewModel.childName }?.id
    }

    private var resolvedChildName: String? {
        if let activeChild {
            return activeChild.name
        }

        if let childDeviceID = UserDefaults.standard.string(forKey: "evlin.childDeviceID") {
            if let match = familyStore.children.first(where: { child in
                child.devices.contains {
                    $0.device_id.caseInsensitiveCompare(childDeviceID) == .orderedSame
                }
            }) {
                return match.display_name
            }
        }

        if let first = familyStore.children.first {
            return first.display_name
        }

        return UserDefaults.standard.string(forKey: "evlin.childProfileName")
    }

    private func syncResolvedChildName() {
        if let name = resolvedChildName {
            viewModel.setChildName(name)
        }
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
            ScrollView {
                ChatScrollMetricsObserver(
                    controller: scrollController,
                    onBottomDistanceChange: { distance in
                        scrollBottomDistance = distance
                    },
                    onContentOffsetYChange: { offsetY in
                        // B6: hide bar on scroll-down, show on scroll-up.
                        let delta = offsetY - lastScrollOffsetY
                        lastScrollOffsetY = offsetY
                        let threshold: CGFloat = 4
                        if delta > threshold && barVisible {
                            barVisible = false
                        } else if delta < -threshold && !barVisible {
                            barVisible = true
                        }
                    }
                )
                .frame(width: 0, height: 0)

                LazyVStack(spacing: Spacing.xxxl) {
                    editorialHeader

                    // Tutorial layer: an empty thread teaches itself — tappable
                    // starter prompts (same curated set + send path as the
                    // composer chips) so the first message writes itself.
                    if viewModel.messages.isEmpty {
                        chatEmptyStarters
                            .tourTarget("chat.starters")
                    }

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
                                // Temporary: the safety card above is a preview
                                // with sample data and its buttons aren't wired
                                // yet. Remove this note when the feature ships.
                                Text("Heads up — this is a placeholder for now. Live safety monitoring is coming soon.")
                                    .font(.evCaption)
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                    targetKind: message.receiptTargetKind ?? .app,
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

                    if let stage = viewModel.stageText {
                        stageIndicator(stage)
                    } else if viewModel.isThinking {
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
                                familyAvatarURLsByChildID: childAvatarURLsByID,
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
                        } else if planArchCard.kind.hasPrefix("event.")
                                    || planArchCard.kind.hasPrefix("target.") {
                            VStack(spacing: Spacing.sm) {
                                EventTargetCardView(
                                    payload: planArchCard,
                                    childName: viewModel.childName,
                                    confirmedTokens: viewModel.confirmedEventTokens,
                                    onConfirm: { token in
                                        await viewModel.handleEventConfirm(token) },
                                    onPickEvent: { ct, eid, occ in
                                        Task { await viewModel.handleEventSelect(ct, eid, occ) } },
                                    onResolveTarget: { ct, ids in
                                        Task { await viewModel.handleResolveTarget(ct, ids) } },
                                    onReflection: { approve, note in
                                        await viewModel.handleReflectionReview(planArchCard, approve: approve, note: note) },
                                    onScope: { ct in
                                        Task { await viewModel.handleEventScope(ct) } },
                                    onSkip: { viewModel.dismissEventCard() },
                                    onAppControlBatch: { ct, choice, duration in
                                        Task {
                                            await viewModel.handleAppControlBatch(
                                                ct, choice, duration)
                                        } })
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
                .padding(.bottom, Self.messageListBottomPadding(keyboardOverlap: keyboardOverlapHeight))
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollController.scrollToBottom(animated: false)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottomIfNeeded(previousBottomDistance: scrollBottomDistance)
            }
            .onChange(of: viewModel.pendingPlanArchCard?.planToken) { _, _ in
                scrollToBottomIfNeeded(previousBottomDistance: scrollBottomDistance)
            }
            .onChange(of: viewModel.currentCard?.0.rawValue) { _, _ in
                scrollToBottomIfNeeded(previousBottomDistance: scrollBottomDistance)
            }
            .onChange(of: viewModel.currentAppControlCard?.kind) { _, _ in
                scrollToBottomIfNeeded(previousBottomDistance: scrollBottomDistance)
            }
            .offset(y: -Self.keyboardContentLift(keyboardOverlap: keyboardOverlapHeight))
            // A single tap anywhere in the chat area hides the top bar; the ONLY
            // way to bring it back is scrolling up. `simultaneousGesture` so it
            // rides alongside message/card taps and never blocks them or scroll.
            .simultaneousGesture(
                TapGesture().onEnded {
                    if barVisible { barVisible = false }
                }
            )

            composerPanel
                .background(Color.evSurfaceContainer)
                .padding(.bottom, Self.composerBottomInset(keyboardOverlap: keyboardOverlapHeight))

            // Floating "jump to latest", layered above the composer so it is
            // never hidden behind it.
            if Self.shouldShowScrollToBottomButton(bottomDistance: scrollBottomDistance) {
                scrollToBottomButton()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(2)
            }

            // B6: collapsing top bar — floats above the scroll view, hides on
            // scroll-down and shows on scroll-up.
            chatTopBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(3)
        }
        .animation(.easeInOut(duration: 0.18), value: isAtBottom)
        .background(Color.evSurfaceContainerLow)
        .onAppear {
            if !isPreview {
                viewModel.apiClient = apiClient
            }
            // A cached device id is not an explicit chat target when the family
            // has multiple kid devices, even when they belong to one child.
            viewModel.childDeviceCountProvider = {
                familyStore.children.reduce(0) { $0 + $1.devices.count }
            }
            syncResolvedChildName()
            guard !isPreview else { return }
            if familyStore.children.isEmpty {
                Task {
                    await familyStore.refresh()
                    syncResolvedChildName()
                }
            }
            viewModel.startReflectionSubmissionPolling()
            Task { await viewModel.tickReflectionSubmissionPoll() }
            // NOTE: the `/parent/reflection/pending-events` poll is intentionally
            // NOT started — it surfaces the SAME submitted reflection as the
            // submission poll above, but as a generic plan-arch card + a plain
            // text bubble ("Your child completed the reflection: …"), which
            // duplicates (and reads worse than) the rich essay-review card
            // `surfaceReflectionSubmissionBubbleIfNeeded` produces ("<child> has
            // finished the reflection…", with Approve / Write-again). One surface.
            // Re-check any receipt still spinning: the kid often acks late
            // (after the 90s poll deadline), so a card can be stuck on
            // "applying now" while the backend is already confirmed.
            viewModel.reconcilePendingReceipts()
        }
        .onChange(of: familyStore.children) { _, _ in
            syncResolvedChildName()
        }
        .onDisappear {
            guard !isPreview else { return }
            viewModel.stopReflectionSubmissionPolling()
            viewModel.stopReflectionEventPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bigKidStateInvalidated)) { _ in
            guard !isPreview else { return }
            Task { await viewModel.tickReflectionSubmissionPoll() }
            // A push / state-invalidation wake often coincides with the kid
            // acking queued commands — re-check stuck receipts so they resolve.
            viewModel.reconcilePendingReceipts()
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
        // B7: History sheet — native swipe-down dismissable sheet.
        .sheet(isPresented: $showHistorySheet) {
            ChatHistorySheet(
                store: viewModel.chatHistoryStore,
                vm: viewModel,
                isPresented: $showHistorySheet
            )
        }
        // B6: Rename alert — TextField lets parent give the current conversation a custom title.
        .alert("Rename Conversation", isPresented: $showRenameAlert) {
            TextField("Conversation name", text: $renameAlertText)
            Button("Save") {
                viewModel.renameCurrentConversation(renameAlertText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this conversation a name.")
        }
    }

    // MARK: - B6: Top bar

    /// Collapsing top bar: History (left) · "Evlin"/title + pencil (center) · Clear (right).
    /// Slides out upward on scroll-down and back in on scroll-up.
    private var chatTopBar: some View {
        HStack(spacing: 0) {
            // LEFT — History button (sheet wired in B7).
            Button {
                showHistorySheet = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // CENTER — tap the whole title (title + pencil) to rename the
            // current conversation. One 44pt-tall button so the tap target is
            // reliably hittable (a bare 14pt pencil was too small to tap).
            Button {
                renameAlertText = viewModel.currentConversationTitle ?? ""
                showRenameAlert = true
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.currentConversationTitle ?? "Evlin")
                        .font(.custom("Manrope", size: 17).weight(.bold))
                        .foregroundStyle(Color.evOnSurface)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename conversation")

            Spacer()

            // RIGHT — New chat: archives the current conversation into history
            // and opens a fresh one (same archive+reset action as the History
            // sheet's "Clear current chat" — relabelled here as New chat so the
            // top bar offers an obvious "start a new conversation" affordance).
            Button {
                viewModel.clear()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, Spacing.xl)
        .frame(height: 48)
        .background(
            Color.evSurfaceContainerLow
                .opacity(0.96)
                .ignoresSafeArea(edges: .top)
        )
        // Fully hide when collapsed: a large slide-up offset clears the top
        // safe area, opacity 0 guarantees nothing peeks at the screen edge, and
        // allowsHitTesting(false) stops the hidden History/New-chat icons from
        // catching taps.
        .offset(y: barVisible ? 0 : -140)
        .opacity(barVisible ? 1 : 0)
        .allowsHitTesting(barVisible)
        .animation(.easeInOut(duration: 0.22), value: barVisible)
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
            .tourTarget("chat.quickPrompts")

            ChatInputBar(text: $viewModel.inputText, isFocused: $isComposerFocused) {
                viewModel.sendMessage()
            }
            .tourTarget("chat.input")
        }
        .padding(.top, Spacing.md)
    }

    /// Floating "jump to latest" affordance, shown only when scrolled up. Sits
    /// just above the composer, which itself floats above the keyboard.
    private func scrollToBottomButton() -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 17, weight: .heavy))
            .foregroundStyle(Color.white)
            .frame(width: 46, height: 46)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                EvlinKidColors.green700.opacity(0.9),
                                EvlinKidColors.green500.opacity(0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
                    .padding(1)
            }
            .contentShape(Circle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        KeyboardDismissGate.suppressNextRootTapDismissal()
                    }
            )
            .onTapGesture {
                KeyboardDismissGate.suppressNextRootTapDismissal()
                let shouldRestoreFocus = Self.shouldRestoreComposerFocusAfterScrollToBottom(
                    wasComposerFocused: isComposerFocused,
                    keyboardOverlap: keyboardOverlapHeight
                )
                scrollController.scrollToBottom(animated: true)
                guard shouldRestoreFocus else { return }
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
            .shadow(color: EvlinKidColors.green700.opacity(0.22), radius: 16, y: 7)
            .shadow(color: Color.white.opacity(0.35), radius: 2, y: -1)
            .padding(.bottom, Self.composerBottomInset(keyboardOverlap: keyboardOverlapHeight) + 132)
            .transition(.opacity)
    }

    private func scrollToBottomIfNeeded(previousBottomDistance: CGFloat) {
        guard Self.shouldAutoPinAfterContentChange(previousBottomDistance: previousBottomDistance) else {
            return
        }
        scrollController.scrollToBottom(animated: true)
    }

    static func shouldAutoPinAfterContentChange(previousBottomDistance: CGFloat) -> Bool {
        previousBottomDistance < autoPinThreshold
    }

    static func shouldAutoPinAfterKeyboardChange(
        previousBottomDistance: CGFloat,
        previousKeyboardOverlap: CGFloat,
        nextKeyboardOverlap: CGFloat
    ) -> Bool {
        false
    }

    static func keyboardContentLift(
        keyboardOverlap: CGFloat,
        tabInset: CGFloat = EvlinTabBar.visibleHeight
    ) -> CGFloat {
        max(0, composerBottomInset(keyboardOverlap: keyboardOverlap, tabInset: tabInset) - tabInset)
    }

    static func shouldShowScrollToBottomButton(bottomDistance: CGFloat) -> Bool {
        bottomDistance >= scrollToBottomButtonThreshold
    }

    static func shouldRestoreComposerFocusAfterScrollToBottom(
        wasComposerFocused: Bool,
        keyboardOverlap: CGFloat
    ) -> Bool {
        wasComposerFocused || keyboardOverlap > 0
    }

    static func stageDotPulse(elapsed: TimeInterval, cycle: TimeInterval = 1.6) -> (scale: CGFloat, opacity: Double) {
        guard cycle > 0 else { return (scale: 0.92, opacity: 0.55) }
        let rawPhase = elapsed.truncatingRemainder(dividingBy: cycle) / cycle
        let phase = rawPhase < 0 ? rawPhase + 1 : rawPhase
        let pulse = sin(phase * .pi)
        return (
            scale: CGFloat(0.92 + 0.36 * pulse),
            opacity: 0.55 + 0.45 * pulse
        )
    }

    static func scrollBottomDistance(contentMaxY: CGFloat, scrollViewportHeight: CGFloat) -> CGFloat {
        guard scrollViewportHeight > 0 else { return 0 }
        return max(0, contentMaxY - scrollViewportHeight)
    }

    static func scrollBottomDistance(
        contentOffsetY: CGFloat,
        contentSizeHeight: CGFloat,
        viewportHeight: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let visibleBottomY = contentOffsetY + viewportHeight - adjustedBottomInset
        return max(0, contentSizeHeight - visibleBottomY)
    }

    static func scrollTargetOffsetY(
        contentSizeHeight: CGFloat,
        viewportHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> CGFloat {
        let minY = -adjustedTopInset
        let maxY = contentSizeHeight - viewportHeight + adjustedBottomInset
        return max(minY, maxY)
    }

    static func scrollToBottomSettleDelays(animated: Bool) -> [Double] {
        animated ? [0, 0.08, 0.18, 0.32] : [0]
    }

    static func clampedContentOffsetY(
        proposedOffsetY: CGFloat,
        contentSizeHeight: CGFloat,
        viewportHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> CGFloat {
        let minY = -adjustedTopInset
        let maxY = scrollTargetOffsetY(
            contentSizeHeight: contentSizeHeight,
            viewportHeight: viewportHeight,
            adjustedTopInset: adjustedTopInset,
            adjustedBottomInset: adjustedBottomInset
        )
        return min(max(proposedOffsetY, minY), maxY)
    }

    static func keyboardUIViewAnimationOption(curveRawValue: UInt) -> UIView.AnimationOptions {
        switch UIView.AnimationCurve(rawValue: Int(curveRawValue)) {
        case .easeIn:
            return .curveEaseIn
        case .easeOut:
            return .curveEaseOut
        case .linear:
            return .curveLinear
        default:
            return .curveEaseInOut
        }
    }

    static var autoPinThreshold: CGFloat { 100 }
    static var scrollToBottomButtonThreshold: CGFloat { 180 }

    static func composerBottomInset(
        keyboardOverlap: CGFloat,
        tabInset: CGFloat = EvlinTabBar.visibleHeight
    ) -> CGFloat {
        max(tabInset, keyboardOverlap)
    }

    static func messageListBottomPadding(
        keyboardOverlap: CGFloat = 0,
        composerPanelHeight: CGFloat = 148,
        tabInset: CGFloat = EvlinTabBar.visibleHeight,
        extraClearance: CGFloat = 28
    ) -> CGFloat {
        // The ScrollView itself is lifted with the composer when the keyboard is
        // visible, so this padding should only reserve the composer/tab clearance.
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

    // MARK: - Empty-thread starter prompts (tutorial layer 3)

    /// Full-width tappable examples shown only while the thread is empty.
    /// Reuses the curated `quickPrompts` set and the same `sendQuickPrompt`
    /// path as the composer chips, so every starter is a known-good request.
    private var chatEmptyStarters: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("TRY ONE TO START")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
            ForEach(Array(viewModel.quickPrompts.prefix(3)), id: \.text) { prompt in
                Button { viewModel.sendQuickPrompt(prompt) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: prompt.icon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(prompt.text)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.evPrimary.opacity(0.45))
                    }
                    .foregroundStyle(Color.evPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.evSurfaceContainerLowest))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Streaming path's pre-envelope status line (e.g. "Checking tasks…"),
    /// preferred over the generic typing dots while a `stage` event is the
    /// most recent thing heard from the backend.
    private func stageIndicator(_ stage: String) -> some View {
        HStack(spacing: 7) {
            StageBreathingDot()
            Text(stage).font(.footnote).foregroundStyle(Color.evOnSurfaceVariant)
        }
        .padding(.vertical, 6)
    }

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

private struct StageBreathingDot: View {
    private let cycle: TimeInterval = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let pulse = ChatView.stageDotPulse(elapsed: elapsed, cycle: cycle)
            ZStack {
                Circle()
                    .fill(Color.evSecondary.opacity(0.18))
                    .frame(width: 13, height: 13)
                    .scaleEffect(0.85 + (pulse.scale - 0.92) * 1.7)
                    .opacity(max(0, pulse.opacity - 0.35))

                Circle()
                    .fill(Color.evSecondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse.scale)
                    .opacity(pulse.opacity)
            }
            .frame(width: 16, height: 16)
        }
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
    ChatView(viewModel: ChatViewModel(), isPreview: true)
        .environmentObject(APIClient(baseURL: "http://preview.local"))
        .environmentObject(ScreenTimeManager.shared)
        .environment(ParentReflectionFixtureStore())
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
