import SwiftUI

enum ReflectionReviewMode: Equatable {
    case approve
    case redo
}

/// Parent-facing review card for a completed kid reflection.
///
/// The visual structure intentionally mirrors the reference card:
/// green completed header, three completion chips, prompt, kid words,
/// Evlin takeaway, and bottom actions. The only product addition is the
/// "Message for Liam" note field, kept directly above the actions.
struct ReflectionSubmissionReviewCard: View {
    let childName: String
    let writingPrompt: String
    let essayText: String
    var mode: ReflectionReviewMode = .approve
    var redoReason: String?
    var resolved: Bool
    var onApprove: (_ parentNoteTrimmed: String) async -> Void
    var onRedo: (() async -> Void)?

    @State private var busy = false
    @State private var parentNote: String = ""

    /// After approve, show what was/will be shown to the kid (blank field -> fallback).
    private var quotedNoteShownToChildAfterApproval: String {
        let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? ReflectionParentNoteFallback.thanksHonest : trimmed
        return "\u{201C}\(body)\u{201D}"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                completionChips
                promptSection
                wordsSection
                takeawaySection

                if !resolved, mode == .approve {
                    parentMessageSection
                }

                if resolved {
                    resolvedNote
                } else {
                    actionRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReflectionPalette.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 24, x: 0, y: 12)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(childInitial)
                .font(.custom("Manrope", size: 17).weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(ReflectionPalette.green, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.custom("Manrope", size: 18).weight(.heavy))
                    .tracking(-0.25)
                    .foregroundStyle(ReflectionPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text("just now · 123")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ReflectionPalette.subtleText)
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: resolved ? "checkmark.circle.fill" : "list.bullet.clipboard.fill")
                    .font(.system(size: 10, weight: .heavy))
                Text(resolved ? "APPROVED" : statusText)
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(2.2)
            }
            .foregroundStyle(ReflectionPalette.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(ReflectionPalette.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ReflectionPalette.line)
                .frame(height: 1)
        }
    }

    private var completionChips: some View {
        ReflectionChipFlowLayout(spacing: 10, rowSpacing: 10) {
            completionChip("Video watched")
            completionChip("Quiz passed")
            completionChip("Essay written")
        }
    }

    private func completionChip(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.system(size: 15, weight: .heavy))
        }
        .foregroundStyle(ReflectionPalette.deepGreen)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ReflectionPalette.chip, in: Capsule())
    }

    private var promptSection: some View {
        sectionCard(label: "Evlin asked") {
            Text(writingPrompt)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(ReflectionPalette.bodyText)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wordsSection: some View {
        sectionCard(label: "\(childName)'s words", accent: true) {
            Text(essayDisplay)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(ReflectionPalette.bodyText)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var takeawaySection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(ReflectionPalette.green, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("Evlin's takeaway")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(ReflectionPalette.green)

                Text(takeawayText)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ReflectionPalette.bodyText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReflectionPalette.takeaway, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var parentMessageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Message for \(childName)")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2.8)
                .textCase(.uppercase)
                .foregroundStyle(ReflectionPalette.label)

            Text("They'll read this on their device after you approve. E.g., \"Thanks for being honest.\"")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ReflectionPalette.subtleText)
                .lineSpacing(2)

            TextField(
                "Add a note for \(childName)...",
                text: $parentNote,
                axis: .vertical
            )
            .font(.system(size: 16, weight: .regular))
            .lineLimit(2...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(ReflectionPalette.bodyText)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ReflectionPalette.line, lineWidth: 1)
            )
        }
        .padding(14)
        .background(ReflectionPalette.messageBg, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(ReflectionPalette.line.opacity(0.9), lineWidth: 1)
        )
    }

    private var resolvedNote: some View {
        Text(quotedNoteShownToChildAfterApproval)
            .font(.system(size: 14, weight: .semibold))
            .italic()
            .foregroundStyle(ReflectionPalette.green)
            .padding(.top, 2)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    busy = true
                    let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    await onApprove(trimmed)
                    busy = false
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .heavy))
                    Text(primaryActionTitle)
                        .font(.system(size: 15, weight: .heavy))
                        .tracking(2.4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(ReflectionPalette.ink, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(busy || essayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                Task {
                    busy = true
                    if let onRedo {
                        await onRedo()
                    }
                    busy = false
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .heavy))
                    Text(secondaryActionTitle)
                        .font(.system(size: 15, weight: .heavy))
                        .tracking(2.4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white, in: Capsule())
                .foregroundStyle(ReflectionPalette.ink)
                .overlay(
                    Capsule()
                        .stroke(ReflectionPalette.line, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(busy || onRedo == nil)
        }
    }

    private func sectionCard<Content: View>(
        label: String,
        accent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .tracking(2.8)
                .textCase(.uppercase)
                .foregroundStyle(ReflectionPalette.label)

            content()
        }
        .padding(.horizontal, accent ? 18 : 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(ReflectionPalette.line, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if accent {
                Capsule()
                    .fill(ReflectionPalette.ink)
                    .frame(width: 5)
                    .padding(.vertical, 4)
            }
        }
    }

    private var childInitial: String {
        String(childName.prefix(1)).uppercased()
    }

    private var headerTitle: String {
        if resolved { return "\(childName) wrote a reflection" }
        switch mode {
        case .approve: return "\(childName) wrote a reflection"
        case .redo: return "Review \(childName)'s reflection"
        }
    }

    private var statusText: String {
        switch mode {
        case .approve: return "COMPLETED"
        case .redo: return "REVIEW"
        }
    }

    private var essayDisplay: String {
        let trimmed = essayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No written reflection was submitted." }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("\u{201C}") {
            return trimmed
        }
        return "\"\(trimmed)\""
    }

    private var takeawayText: String {
        let lowered = essayText.lowercased()
        if lowered.contains("sorry") || lowered.contains("next time") {
            return "\(childName) named a repair step and described what they can try next time. Good opening to reinforce the replacement behavior."
        }
        return "\(childName) connected the situation to a concrete reflection. Good opening to coach the next right step."
    }

    private var primaryActionTitle: String {
        busy ? "WORKING" : "GOOD ENOUGH"
    }

    private var secondaryActionTitle: String {
        mode == .redo ? "SEND BACK" : "WRITE AGAIN"
    }
}

private enum ReflectionPalette {
    static let header = Color(hex: 0xEAF7EC)
    static let chip = Color(hex: 0xE8F5E9)
    static let takeaway = Color(hex: 0xE8F5E9)
    static let messageBg = Color(hex: 0xF6FAF7)
    static let green = Color(hex: 0x2E8B3C)
    static let deepGreen = Color(hex: 0x1D6A2A)
    static let ink = Color(hex: 0x061A2B)
    static let bodyText = Color(hex: 0x171C20)
    static let subtleText = Color(hex: 0x596066)
    static let label = Color(hex: 0x5E636A)
    static let line = Color(hex: 0xDDE2E6)
}

private struct ReflectionChipFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + rowSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth == 0 ? size.width : spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == 0 ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Reflection Review Card") {
    ScrollView {
        ReflectionSubmissionReviewCard(
            childName: "Liam",
            writingPrompt: "What was happening just before you felt upset, and what did your body feel like?",
            essayText: "I was almost done with a build and the timer cut me off. My chest got hot and I wanted to throw my iPad. I wish I had saved sooner so I didn't lose progress.",
            resolved: false,
            onApprove: { _ in },
            onRedo: {}
        )
        .padding()
    }
    .background(Color.evSurfaceContainerLow)
}
