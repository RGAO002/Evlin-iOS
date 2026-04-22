import SwiftUI

struct TaskItem: Identifiable, Hashable {
    let id: Int
    var title: String
    var state: State
    var iconSystemName: String?

    enum State: String, Hashable {
        case pending, done, review, overdue
        var label: String {
            switch self {
            case .pending: return "Pending"
            case .done: return "Done"
            case .review: return "Reviewing"
            case .overdue: return "Overdue"
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            mainRow
            if task.state == .review {
                reviewActions
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

    private var cardBackground: Color {
        switch task.state {
        case .review:  return Color(hex: 0xFFF9ED)
        case .overdue: return Color(hex: 0xFFF5F3)
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
