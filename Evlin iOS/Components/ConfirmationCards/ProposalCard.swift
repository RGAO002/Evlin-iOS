import SwiftUI

/// Generic AI proposal card — surface AI-staged tool calls for parent
/// approval. One card per Proposal in the agent response. Tap Confirm
/// → POST /parent/agent/exec → in-place becomes a ReceiptBubble.
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: dangerIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(dangerColor)
                Text(proposal.label)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evOnSurface)
            }
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineSpacing(2)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : "Confirm")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(dangerColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(working)
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.evSurfaceContainerLow)
                        .foregroundStyle(Color.evOnSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(16)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dangerColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var dangerColor: Color {
        switch proposal.danger {
        case "high": return Color.evError
        case "medium": return Color.orange
        default: return Color.evSecondary
        }
    }

    private var dangerIcon: String {
        switch proposal.danger {
        case "high": return "exclamationmark.triangle.fill"
        case "medium": return "questionmark.circle.fill"
        default: return "sparkles"
        }
    }

    private var bodyText: String {
        // For v1, pull a few common keys from args. AI's `label` already
        // describes the action; this gives extra context.
        if let reason = proposal.args["reason"]?.value as? String {
            return "Reason: \"\(reason)\""
        }
        if let title = proposal.args["title"]?.value as? String {
            return "Title: \(title)"
        }
        if let minutes = proposal.args["minutes"]?.value as? Int {
            return "Duration: \(minutes) min"
        }
        return ""
    }
}
