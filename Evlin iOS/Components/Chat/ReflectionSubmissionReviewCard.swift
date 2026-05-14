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
///    + tri-state status pill (yellow Open / green Completed / red Sent back).
///  - Subtitle line "just now · {topic}" below the title.
///  - Three step pills (video / quiz / essay) marking the kid's progress.
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
    /// Backend submission timestamp. The card renders a relative-time
    /// prefix ("Just now / 5m ago / 2h ago") in its subtitle when set.
    var submittedAt: Date? = nil
    /// AI-summarised ≤3-word topic chip (e.g. "Sibling Conflict").
    /// Shown after the "·" in the subtitle. nil suppresses both halves.
    var topicLabel: String? = nil
    /// Kid's progress through the 3 reflection steps. Drives the
    /// video/quiz/essay pill row under the header. Empty array hides
    /// the row.
    var stepsCompleted: [BigKidReflectionStep] = []
    /// Optional takeaway line. When nil a coached default is derived
    /// from the essay content.
    var takeaway: String? = nil
    var mode: ReflectionReviewMode = .approve
    var redoReason: String?
    /// Tri-state review status. Drives the header pill's color and
    /// label, and which body content ("Message for kid" editor +
    /// actions row vs the resolved-note line) is shown.
    var status: ReflectionReviewStatus
    var onApprove: (_ parentNoteTrimmed: String) async -> Void
    /// Receives the SAME trimmed parent-note string as `onApprove` —
    /// the call site is expected to substitute the
    /// `ReflectionParentNoteFallback.redoTakeAnotherLook` default when
    /// the trimmed string is empty, so the kid always sees a coached
    /// message on the rework screen.
    var onRedo: ((_ parentNoteTrimmed: String) async -> Void)?

    @State private var busy = false
    @State private var parentNote: String = ""

    /// After approve, show what was/will be shown to the kid (blank field -> fallback).
    private var quotedNoteShownToChildAfterApproval: String {
        let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? ReflectionParentNoteFallback.thanksHonest : trimmed
        return "\u{201C}\(body)\u{201D}"
    }

    private var resolved: Bool { status != .open }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 12) {
                if !stepsCompleted.isEmpty {
                    stepPillsRow
                }
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

    @ViewBuilder
    private var tonePill: some View {
        let cfg = pillConfig(for: status)
        HStack(spacing: 4) {
            Image(systemName: cfg.icon)
                .font(.system(size: 10, weight: .heavy))
            Text(cfg.label)
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(0.6)
                .textCase(.uppercase)
        }
        .foregroundStyle(cfg.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(cfg.background))
        .overlay(Capsule().stroke(cfg.stroke, lineWidth: 1))
    }

    private struct PillConfig {
        let icon: String
        let label: String
        let foreground: Color
        let background: Color
        let stroke: Color
    }

    private func pillConfig(for status: ReflectionReviewStatus) -> PillConfig {
        switch status {
        case .open:
            // Yellow chip — kid submitted, parent hasn't decided yet.
            // Slightly warmer amber so it reads as "needs attention"
            // without crossing into error / red territory.
            let amber = Color(red: 0.78, green: 0.45, blue: 0.06)
            return PillConfig(
                icon: "square.and.pencil",
                label: "Open",
                foreground: amber,
                background: Color(red: 1.0, green: 0.94, blue: 0.79),
                stroke: amber.opacity(0.35)
            )
        case .approved:
            // Green chip — parent tapped "Good enough".
            return PillConfig(
                icon: "checkmark.seal.fill",
                label: "Completed",
                foreground: Color.evSecondary,
                background: Color.evSecondaryContainer.opacity(0.6),
                stroke: Color.evSecondary.opacity(0.35)
            )
        case .sentBack:
            // Red chip — parent tapped "Write again".
            let red = Color(red: 0.72, green: 0.20, blue: 0.20)
            return PillConfig(
                icon: "arrow.uturn.backward.circle.fill",
                label: "Sent Back",
                foreground: red,
                background: Color(red: 1.0, green: 0.91, blue: 0.91),
                stroke: red.opacity(0.35)
            )
        }
    }

    // MARK: - Step pills (video / quiz / essay)

    private var stepPillsRow: some View {
        HStack(spacing: 6) {
            stepPill(label: "Video", step: .video)
            stepPill(label: "Quiz", step: .quiz)
            stepPill(label: "Essay", step: .writing)
            Spacer(minLength: 0)
        }
    }

    private func stepPill(label: String, step: BigKidReflectionStep) -> some View {
        let done = stepsCompleted.contains(step)
        return HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(0.4)
        }
        .foregroundStyle(done ? Color.evSecondary : Color.evOnSurfaceVariant)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                done ? Color.evSecondaryContainer.opacity(0.55)
                     : Color.evSurfaceContainerLow
            )
        )
        .overlay(
            Capsule().stroke(
                done ? Color.evSecondary.opacity(0.25) : Color.evOutlineVariant,
                lineWidth: 1
            )
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
        // CSS analogue: `border: 1px solid outlineVariant; border-left: 3px solid primary;`
        // both following border-radius. SwiftUI doesn't support
        // per-edge borders natively, so we render the navy column
        // BEFORE the clipShape — then clip everything to the rounded
        // shape so the column's top/bottom ends curve along with the
        // card corners. The thin outer stroke is applied AFTER the
        // clip as a 1px stroke that traces the rounded boundary.
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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.evPrimary)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
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

    @ViewBuilder
    private var resolvedNote: some View {
        switch status {
        case .approved:
            Text(quotedNoteShownToChildAfterApproval)
                .font(.custom("Inter", size: 12.5))
                .italic()
                .foregroundStyle(Color.evSecondary)
                .padding(.top, 2)
        case .sentBack:
            Text("Sent back to \(childName) — they'll see your note on the rework screen.")
                .font(.custom("Inter", size: 12.5))
                .italic()
                .foregroundStyle(Color(red: 0.72, green: 0.20, blue: 0.20))
                .padding(.top, 2)
        case .open:
            // Defensive — should never render in .open since callers
            // gate this view behind `resolved`. Empty branch keeps the
            // switch exhaustive.
            EmptyView()
        }
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
        // Always clickable by default. If the call site didn't wire
        // `onRedo` (e.g. chat-side `reflectionSubmissionReview` that
        // historically only supported approve), fall back to a no-op
        // dismiss so the button still feels alive instead of dead.
        Button {
            Task {
                busy = true
                let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
                if let onRedo {
                    await onRedo(trimmed)
                } else {
                    // Cosmetic delay so the button shows the busy state
                    // briefly even when there's no real handler.
                    try? await Task.sleep(nanoseconds: 200_000_000)
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
        .disabled(busy)
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
        let parts: [String] = [relativeTimeString, topicLabelString].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// "Just now" / "5m ago" / "2h ago" / "Yesterday" — humanised
    /// relative time used in the subtitle's left half. nil when no
    /// `submittedAt` was provided (older payloads / fixtures).
    private var relativeTimeString: String? {
        guard let submittedAt else { return nil }
        let delta = Date().timeIntervalSince(submittedAt)
        if delta < 60 { return "Just now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(delta / 3600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(delta / 86_400)
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: submittedAt)
    }

    /// Topic chip text for the subtitle's right half. Empty / whitespace
    /// inputs are suppressed so the `·` separator doesn't render alone.
    private var topicLabelString: String? {
        guard let topicLabel else { return nil }
        let trimmed = topicLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        VStack(spacing: 16) {
            ReflectionSubmissionReviewCard(
                childName: "Liam",
                writingPrompt: "What was happening just before you felt upset, and what did your body feel like?",
                essayText: "I was almost done with a build and the timer cut me off. My chest got hot and I wanted to throw my iPad.",
                submittedAt: Date().addingTimeInterval(-90),
                topicLabel: "Screen Time Limit",
                stepsCompleted: [.video, .quiz, .writing],
                takeaway: "Liam is connecting the trigger to a body cue.",
                status: .open,
                onApprove: { _ in },
                onRedo: { _ in }
            )
            ReflectionSubmissionReviewCard(
                childName: "Liam",
                writingPrompt: "What happened, how did it affect someone else?",
                essayText: "I called Maya a baby and she cried. I should have walked away.",
                submittedAt: Date().addingTimeInterval(-3600),
                topicLabel: "Sibling Conflict",
                stepsCompleted: [.video, .quiz, .writing],
                status: .approved,
                onApprove: { _ in },
                onRedo: { _ in }
            )
            ReflectionSubmissionReviewCard(
                childName: "Liam",
                writingPrompt: "What happened, how did it affect someone else?",
                essayText: "idk just felt mad",
                submittedAt: Date().addingTimeInterval(-86_400),
                topicLabel: "Hurtful Words",
                stepsCompleted: [.video, .quiz, .writing],
                status: .sentBack,
                onApprove: { _ in },
                onRedo: { _ in }
            )
        }
        .padding()
    }
    .background(Color.evSurfaceContainerLow)
}
