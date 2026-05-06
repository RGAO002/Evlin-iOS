import SwiftUI

/// Generic AI proposal card. When `aliasMissTarget` is non-nil, renders an
/// orange warning row + "Tag <target>" button and disables Confirm — the
/// view model removes the miss after lazy-tag flow saves an alias, at
/// which point the next render unblocks Confirm.
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    var aliasMissTarget: String? = nil
    var onTag: () -> Void = {}
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
            if let missTarget = aliasMissTarget {
                aliasMissBlock(target: missTarget)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : "Confirm")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(confirmBackground)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(confirmDisabled)
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

    @ViewBuilder
    private func aliasMissBlock(target: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .font(.system(size: 13))
                Text("First time locking \u{201C}\(target)\u{201D} — tap below to confirm which app it is.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            Button(action: onTag) {
                Text("Tag \(target)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var confirmDisabled: Bool { working || aliasMissTarget != nil }

    private var confirmBackground: Color {
        aliasMissTarget != nil ? Color.evOutline : dangerColor
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
