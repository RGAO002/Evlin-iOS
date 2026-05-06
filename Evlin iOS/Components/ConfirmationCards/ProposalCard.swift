import SwiftUI

/// Generic AI proposal card. Supports single-row (legacy `args["target"]`
/// + `args["target_kind"]`) and multi-row (`args["rows"]` array of
/// `{target, target_kind, minutes}`) layouts. Per-row alias-miss UI:
/// each row that misses LocalAliasStore lookup shows a "Tag" button;
/// Confirm is disabled until every row is resolved.
struct ProposalCard: View {
    let proposal: ProposalDTO
    var onConfirm: () async -> Void
    var onSkip: () -> Void
    /// Index-aligned with `rows`. nil means the row is good. Caller
    /// (ChatView) supplies via `viewModel.rowAliasMissTargets(for:)`.
    var rowAliasMissTargets: [String?] = []
    var onTagRow: (Int) -> Void = { _ in }
    @State private var working = false

    private var rows: [(target: String, kind: String, minutes: Int?)] {
        if let rowsAny = proposal.args["rows"]?.value as? [Any] {
            return rowsAny.compactMap { r in
                guard let dict = r as? [String: Any],
                      let target = dict["target"] as? String,
                      let kind = dict["target_kind"] as? String
                else { return nil }
                let minutes = dict["minutes"] as? Int
                return (target, kind, minutes)
            }
        }
        // Legacy shape: derive single row from top-level args
        if let target = proposal.args["target"]?.value as? String,
           let kind = proposal.args["target_kind"]?.value as? String {
            let minutes = proposal.args["minutes"]?.value as? Int
            return [(target, kind, minutes)]
        }
        return []
    }

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
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                rowView(idx: idx, row: row)
            }
            HStack(spacing: 10) {
                Button(action: { Task { await runConfirm() } }) {
                    Text(working ? "Working…" : (rows.count > 1 ? "Confirm all" : "Confirm"))
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
    private func rowView(idx: Int, row: (target: String, kind: String, minutes: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NameWithIcon(
                    name: row.target,
                    kind: row.kind == "category" ? .category : .app,
                    titleFont: .system(size: 15, weight: .medium)
                )
                Spacer()
                if rowMissTarget(idx: idx) == nil && rows.count > 1 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                }
            }
            if let missTarget = rowMissTarget(idx: idx) {
                Button(action: { onTagRow(idx) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text("First time locking — tap to confirm \"\(missTarget)\"")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(8)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func rowMissTarget(idx: Int) -> String? {
        guard idx < rowAliasMissTargets.count else { return nil }
        return rowAliasMissTargets[idx]
    }

    private func runConfirm() async {
        working = true
        await onConfirm()
        working = false
    }

    private var confirmDisabled: Bool {
        working || rowAliasMissTargets.contains(where: { $0 != nil })
    }

    private var confirmBackground: Color {
        rowAliasMissTargets.contains(where: { $0 != nil }) ? Color.evOutline : dangerColor
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
}
