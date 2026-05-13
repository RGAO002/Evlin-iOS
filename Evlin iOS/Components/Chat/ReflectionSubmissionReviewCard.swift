import SwiftUI

enum ReflectionReviewMode: Equatable {
    case approve
    case redo
}

/// Parent-facing review card for a completed kid reflection.
///
/// Visual structure mirrors `frontend_for_app_evlin/Evlin_Parent_view/
/// screen-evlin.jsx :: ReflectionCard`:
///  - Green header strip with avatar initial + "{name} wrote a reflection"
///    + small success pill ("Reviewed" / tone text).
///  - "Evlin asked" prompt section in the project's neutral surface.
///  - "{name}'s words" section with a 3px navy left border.
///  - "Evlin's takeaway" section over the project's secondary container.
///  - Bottom actions: "Good enough" filled + "Write again" ghost.
///
/// The only product extension on top of the reference is the
/// "Message for {childName}" parent note input — kept above the action row.
struct ReflectionSubmissionReviewCard: View {
    let childName: String
    let writingPrompt: String
    let essayText: String
    /// Subtitle anchor — e.g. `"Just now"`, `"2 min ago"`. Optional;
    /// when nil the trigger renders alone.
    var submittedAt: String? = nil
    /// Reflection trigger / reason — e.g. `"After Roblox lockout"`.
    /// Optional; when nil and `submittedAt` is also nil, the subtitle
    /// is suppressed entirely (no placeholder text).
    var trigger: String? = nil
    /// Short status tone shown in the header pill — e.g. `"open"`,
    /// `"ready"`. Falls back to `mode`-appropriate copy when nil.
    var tone: String? = nil
    /// Optional takeaway line. When nil a coached default is derived
    /// from the essay content.
    var takeaway: String? = nil
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

            VStack(alignment: .leading, spacing: 12) {
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
            .padding(14)
        }
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(childInitial)
                .font(.custom("Manrope", size: 13).weight(.heavy))
                .tracking(-0.3)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Color.evSecondary,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("\(childName) wrote a reflection")
                    .font(.custom("Manrope", size: 13).weight(.heavy))
                    .tracking(-0.13)
                    .foregroundStyle(Color.evOnSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.custom("Inter", size: 10.5).weight(.semibold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            tonePill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSecondaryContainer)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 1)
        }
    }

    private var tonePill: some View {
        HStack(spacing: 4) {
            Image(systemName: resolved ? "checkmark.seal.fill" : "square.and.pencil")
                .font(.system(size: 10, weight: .heavy))
            Text(toneLabel)
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(0.6)
                .textCase(.uppercase)
        }
        .foregroundStyle(Color.evSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.evSecondaryContainer.opacity(0.5))
        )
        .overlay(
            Capsule().stroke(Color.evSecondary.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Body sections

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Evlin asked", color: Color.evOnSurfaceVariant)
            Text(writingPrompt)
                .font(.custom("Inter", size: 12.5))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("\(childName)'s words", color: Color.evPrimary)
            Text(essayDisplay)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.evPrimary)
                .frame(width: 3)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
        }
    }

    private var takeawaySection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Color.evSecondary,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Evlin's takeaway")
                    .font(.custom("Manrope", size: 11).weight(.heavy))
                    .foregroundStyle(Color.evSecondary)

                Text(takeawayText)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSecondaryContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var parentMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Message for \(childName)", color: Color.evOnSurfaceVariant)

            Text("They'll read this on their device after you approve.")
                .font(.custom("Inter", size: 11.5))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(2)

            TextField(
                "Add a note for \(childName)…",
                text: $parentNote,
                axis: .vertical
            )
            .font(.custom("Inter", size: 13))
            .lineLimit(2...4)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.white,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(Color.evOnSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
        }
    }

    private var resolvedNote: some View {
        Text(quotedNoteShownToChildAfterApproval)
            .font(.custom("Inter", size: 12.5))
            .italic()
            .foregroundStyle(Color.evSecondary)
            .padding(.top, 2)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            primaryActionButton
            secondaryActionButton
        }
    }

    private var primaryActionButton: some View {
        Button {
            Task {
                busy = true
                let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
                await onApprove(trimmed)
                busy = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13, weight: .heavy))
                Text(primaryActionTitle)
                    .font(.custom("Inter", size: 12.5).weight(.heavy))
                    .tracking(-0.1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                Color.evSecondary,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(busy || essayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var secondaryActionButton: some View {
        Button {
            Task {
                busy = true
                if let onRedo {
                    await onRedo()
                }
                busy = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .heavy))
                Text(secondaryActionTitle)
                    .font(.custom("Inter", size: 12.5).weight(.heavy))
                    .tracking(-0.1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                Color.evSurfaceContainerLow,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(Color.evOnSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy || onRedo == nil)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("Inter", size: 9.5).weight(.heavy))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    private var childInitial: String {
        String(childName.prefix(1)).uppercased()
    }

    private var headerSubtitle: String? {
        let parts = [submittedAt, trigger].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return value
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private var toneLabel: String {
        if let tone, !tone.isEmpty { return tone }
        if resolved { return "Reviewed" }
        switch mode {
        case .approve: return "Open"
        case .redo: return "Review"
        }
    }

    private var essayDisplay: String {
        let trimmed = essayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No written reflection was submitted." }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("\u{201C}") {
            return trimmed
        }
        return "\u{201C}\(trimmed)\u{201D}"
    }

    private var takeawayText: String {
        if let takeaway, !takeaway.isEmpty { return takeaway }
        let lowered = essayText.lowercased()
        if lowered.contains("sorry") || lowered.contains("next time") {
            return "\(childName) named a repair step and described what they can try next time."
        }
        return "\(childName) connected the situation to a concrete reflection."
    }

    private var primaryActionTitle: String {
        busy ? "Working…" : "Good enough"
    }

    private var secondaryActionTitle: String {
        mode == .redo ? "Send back" : "Write again"
    }
}

#Preview("Reflection Review Card") {
    ScrollView {
        ReflectionSubmissionReviewCard(
            childName: "Liam",
            writingPrompt: "What was happening just before you felt upset, and what did your body feel like?",
            essayText: "I was almost done with a build and the timer cut me off. My chest got hot and I wanted to throw my iPad. I wish I had saved sooner so I didn't lose progress.",
            submittedAt: "Just now",
            trigger: "After Roblox lockout",
            tone: "Open",
            takeaway: "Liam is connecting the trigger to a body cue.",
            resolved: false,
            onApprove: { _ in },
            onRedo: {}
        )
        .padding()
    }
    .background(Color.evSurfaceContainerLow)
}
