import SwiftUI

struct ChatView: View {
    @EnvironmentObject var apiClient: APIClient
    @StateObject private var viewModel = ChatViewModel()
    var isPreview = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Spacing.xxxl) {
                        editorialHeader

                        ForEach(viewModel.messages) { message in
                            VStack(alignment: message.role == .parent ? .trailing : .leading, spacing: Spacing.xl) {
                                // Reasoning card
                                if let reasoning = message.reasoning, message.role == .agent {
                                    AgentReasoningCard(label: "Strategic Context", content: reasoning)
                                }

                                // Lock confirmation card
                                if let mins = message.lockMinutes, let name = message.lockChildName {
                                    LockConfirmationCard(minutes: mins, childName: name)
                                }

                                // Chat bubble
                                ChatBubble(content: message.content, role: message.role, timestamp: message.timestamp)

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
                            }
                            .id(message.id)
                        }

                        if viewModel.isThinking {
                            thinkingIndicator
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
            .background(Color.evSurface)
        }
        .background(Color.evSurface)
        .onAppear {
            if !isPreview {
                viewModel.apiClient = apiClient
            }
        }
    }

    // MARK: - Editorial Header

    private var editorialHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Deep Analysis")
                .font(.system(size: 40, weight: .heavy, design: .default))
                .foregroundStyle(Color.evPrimary)
                .tracking(-0.5)

            Text("Strategic Advisory")
                .font(.system(size: 40, weight: .heavy, design: .default))
                .foregroundStyle(Color.evOnPrimaryContainer)
                .tracking(-0.5)

            Text("Evlin is currently monitoring behavioral patterns from the last 72 hours. Ask about strategy adjustments.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(3)
                .padding(.top, Spacing.xl)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.section)
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
