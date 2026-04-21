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
            case .review: return "Review"
            case .overdue: return "Overdue"
            }
        }
        var tone: EvlinPillTone {
            switch self {
            case .pending: return .neutral
            case .done: return .success
            case .review: return .warn
            case .overdue: return .danger
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    var isLast: Bool = false
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.evSurfaceContainerLow)
                Image(systemName: task.iconSystemName ?? defaultIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.custom("Manrope", size: 14).weight(.bold))
                    .foregroundStyle(Color.evPrimary)
                EvlinPill(text: task.state.label, tone: task.state.tone, size: .xs)
            }
            Spacer()
            if task.state == .review {
                Button(action: onApprove) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSecondary))
                }
                .buttonStyle(.plain)
                Button(action: onRedo) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.evPrimary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.evSurfaceContainerHigh))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(Color.evOutlineVariant.opacity(isLast ? 0 : 0.4))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var defaultIcon: String {
        switch task.state {
        case .done: return "checkmark.circle.fill"
        case .review: return "eye"
        case .pending: return "clock"
        case .overdue: return "exclamationmark.circle"
        }
    }
}
