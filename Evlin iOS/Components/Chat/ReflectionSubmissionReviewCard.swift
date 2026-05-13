import SwiftUI

/// Mirrors `ParentBigKidDebugSheet`'s approve flow — essay + prompt + optional parent
/// note (`POST /parent/reflection/:id/approve`), surfaced inline in Chat.
struct ReflectionSubmissionReviewCard: View {
    let childName: String
    let writingPrompt: String
    let essayText: String
    var resolved: Bool
    var onApprove: (_ parentNoteTrimmed: String) async -> Void

    @State private var busy = false
    @State private var parentNote: String = ""

    /// After approve, show what was/will be shown to the kid (blank field → fallback).
    private var quotedNoteShownToChildAfterApproval: String {
        let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? ReflectionParentNoteFallback.thanksHonest : trimmed
        return "\u{201C}\(body)\u{201D}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: resolved ? "checkmark.seal.fill" : "text.book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(resolved ? Color.evSecondary : Color.evReflectionBorder)
                    .frame(width: 34, height: 34)
                    .background(Color.evSurfaceContainerLowest.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Text(resolved ? "Reflection approved" : "Approve reflection")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evPrimary)
            }

            if !resolved {
                Text("\(childName) finished every reflection step and submitted their essay. Review below — optionally write a short message they’ll see on their device, then approve.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evOnReflectionBadge)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Essay prompt")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnReflectionBadge)
                    .textCase(.uppercase)

                Text(writingPrompt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.evPrimary)
                    .lineSpacing(2)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.evSurfaceContainerLowest.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .stroke(Color.evReflectionBorder.opacity(0.28), lineWidth: 1)
                    )

                Text("Their reflection")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnReflectionBadge)
                    .textCase(.uppercase)
                    .padding(.top, 4)

                Text(essayText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.evSurfaceContainerLowest.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .stroke(Color.evReflectionBorder.opacity(0.32), lineWidth: 1)
                    )
            }

            if !resolved {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Message for \(childName)")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .textCase(.uppercase)

                    Text("They’ll read this on their phone after you approve. E.g., “Thanks for being honest.”")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .lineSpacing(2)

                    TextField(
                        "Add a note for \(childName)...",
                        text: $parentNote,
                        axis: .vertical
                    )
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .padding(Spacing.md)
                    .background(Color.evSurfaceContainerLowest.opacity(0.84).clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg)))
                    .foregroundStyle(Color.evOnSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .stroke(Color.evReflectionBorder.opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(Spacing.md)
                .background(Color.evReflectionBadge.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .stroke(Color.evReflectionBorder.opacity(0.25), lineWidth: 1)
                )

                Button {
                    Task {
                        busy = true
                        let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        await onApprove(trimmed)
                        busy = false
                    }
                } label: {
                    Text(busy ? "Approving…" : "Approve")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(Color.evSurfaceContainerLowest.opacity(0.88))
                        .foregroundStyle(Color.evPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.lg)
                                .stroke(Color.evReflectionBorder, lineWidth: 1.5)
                        )
                }
                .disabled(busy || essayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(quotedNoteShownToChildAfterApproval)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(Color.evOnReflectionBadge)
            }
        }
        .padding(Spacing.lg)
        .background(
            LinearGradient(
                colors: [
                    Color.evReflectionSurface,
                    Color.evSurfaceContainerLowest
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .stroke(Color.evReflectionBorder.opacity(0.62), lineWidth: 1)
        )
        .evShadow(.premium)
    }
}
