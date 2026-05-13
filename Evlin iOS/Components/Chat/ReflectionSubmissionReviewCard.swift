import SwiftUI

enum ReflectionReviewMode: Equatable {
    case approve
    case redo
}

/// Mirrors `ParentBigKidDebugSheet`'s approve flow — essay + prompt + optional parent
/// note (`POST /parent/reflection/:id/approve`), surfaced inline in Chat.
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

    /// After approve, show what was/will be shown to the kid (blank field → fallback).
    private var quotedNoteShownToChildAfterApproval: String {
        let trimmed = parentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? ReflectionParentNoteFallback.thanksHonest : trimmed
        return "\u{201C}\(body)\u{201D}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(resolved ? Color.evSecondary : headerAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.evSurfaceContainerLowest.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Text(headerTitle)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Color.evPrimary)
            }

            if !resolved {
                Text(introCopy)
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

            if !resolved, mode == .approve {
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
            } else if !resolved {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(redoReason == nil ? "Redo request" : "Redo reason")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnReflectionBadge)
                        .textCase(.uppercase)

                    Text(redoReasonDisplay)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.evPrimary)
                        .lineSpacing(2)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.evReflectionBadge.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .stroke(Color.evReflectionBorder.opacity(0.25), lineWidth: 1)
                )

                Button {
                    Task {
                        busy = true
                        if let onRedo {
                            await onRedo()
                        } else {
                            await onApprove("")
                        }
                        busy = false
                    }
                } label: {
                    Text(busy ? "Sending…" : "Send for redo")
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

    private var headerIcon: String {
        if resolved { return "checkmark.seal.fill" }
        switch mode {
        case .approve: return "text.book.closed.fill"
        case .redo: return "arrow.triangle.2.circlepath"
        }
    }

    private var headerAccent: Color {
        switch mode {
        case .approve: return Color.evReflectionBorder
        case .redo: return Color.evOnTertiaryContainer
        }
    }

    private var headerTitle: String {
        if resolved { return "Reflection approved" }
        switch mode {
        case .approve: return "Approve reflection"
        case .redo: return "Send reflection back?"
        }
    }

    private var introCopy: String {
        switch mode {
        case .approve:
            return "\(childName) finished every reflection step and submitted their essay. Review below — optionally write a short message they’ll see on their device, then approve."
        case .redo:
            return "\(childName) finished every reflection step and submitted their essay. Review below before sending it back for another try."
        }
    }

    private var redoReasonDisplay: String {
        guard let reason = redoReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else {
            return "Ask \(childName) to write again with more detail and care before their device moves forward."
        }
        return reason
    }
}
