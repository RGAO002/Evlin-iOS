import SwiftUI

struct TaskItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var state: State
    var iconSystemName: String?

    // Rich data (Phase 1 — for TaskDetailSheet, see HTML 730-865)
    var category: String? = nil           // "Chore" | "Homework" | "Reading" | "Routine"
    var description: String? = nil        // "What to do" body
    var photos: [String] = []             // submission photo URLs
    var note: String? = nil               // child's note OR bypass reason
    var submittedAt: String? = nil        // "3:18 PM"
    var dueLabel: String? = nil           // "Today, 4:00 PM"

    enum State: String, Hashable {
        case pending, done, review, overdue, bypass, bypassed
        var label: String {
            switch self {
            case .pending:  return "Pending"
            case .done:     return "Done"
            case .review:   return "Reviewing"
            case .overdue:  return "Overdue"
            case .bypass:   return "Bypass requested"
            case .bypassed: return "Bypassed"
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 14) {
                mainRow
                if task.state == .review {
                    reviewActions
                        .contentShape(Rectangle())
                        .onTapGesture { /* swallow row tap */ }
                }
                if task.state == .bypass {
                    bypassActions
                        .contentShape(Rectangle())
                        .onTapGesture { /* swallow row tap */ }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: Color {
        switch task.state {
        case .review:  return Color(hex: 0xFFF9ED)
        case .overdue: return Color(hex: 0xFFF5F3)
        case .bypass:  return Color(hex: 0xF7F2FF)   // pale purple
        default:       return .evSurfaceContainerLowest
        }
    }

    private var mainRow: some View {
        HStack(spacing: 14) {
            stateIcon
            titleText
            Spacer(minLength: 4)
            trailingLabel
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evOutline)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch task.state {
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evSecondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

        case .review:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: 0xEF6C00))
                Image(systemName: task.iconSystemName ?? "camera.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

        case .pending:
            Circle()
                .stroke(Color.evOutline, lineWidth: 1.5)
                .frame(width: 28, height: 28)
                .padding(4)

        case .overdue:
            ZStack {
                Circle().stroke(Color.evError, lineWidth: 1.5)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.evError)
            }
            .frame(width: 28, height: 28)
            .padding(4)

        case .bypass:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: 0x7C3AED))    // BYPASS_PURPLE per HTML 483
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

        case .bypassed:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.evOutlineVariant, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.evSurfaceContainerLowest)
                    )
                Image(systemName: "nosign")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.evOutline)
            }
            .frame(width: 36, height: 36)
        }
    }

    private var titleText: some View {
        Group {
            if task.state == .done {
                Text(task.title)
                    .strikethrough(true, color: Color.evOnSurfaceVariant)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            } else {
                Text(task.title)
                    .foregroundStyle(Color.evPrimary)
            }
        }
        .font(.custom("Manrope", size: 16).weight(.heavy))
    }

    @ViewBuilder
    private var trailingLabel: some View {
        switch task.state {
        case .done:
            EvlinPill(text: "Done", tone: .success, size: .xs)
        case .review:
            EvlinPill(text: "Reviewing", tone: .warn, size: .xs)
        case .pending:
            EvlinPill(text: "Pending", tone: .neutral, size: .xs)
        case .overdue:
            Text("OVERDUE")
                .font(.custom("Inter", size: 11).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evError)

        case .bypass:
            Text("BYPASS REQUESTED")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color(hex: 0x7C3AED))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: 0x7C3AED).opacity(0.12)))

        case .bypassed:
            EvlinPill(text: "Bypassed", tone: .neutral, size: .xs)
        }
    }

    private var bypassActions: some View {
        HStack(spacing: 10) {
            Button(action: onApprove) {
                Text("ALLOW")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(EvlinAddPalette.bypass)
                    )
                    .shadow(color: EvlinAddPalette.bypass.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button(action: onRedo) {
                Text("DENY")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.evOnTertiaryContainer)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(hex: 0xEF6C00), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var reviewActions: some View {
        HStack(spacing: 10) {
            Button(action: onApprove) {
                Text("APPROVE")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.evSecondary)
                    )
                    .shadow(color: Color.evSecondary.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)

            Button(action: onRedo) {
                Text("REQUEST REDO")
                    .font(.custom("Manrope", size: 12).weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.evOnTertiaryContainer)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(hex: 0xEF6C00), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}
