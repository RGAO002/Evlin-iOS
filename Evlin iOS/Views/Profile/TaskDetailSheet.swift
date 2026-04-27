import SwiftUI

/// Full-screen task detail. See HTML 730-865.
/// Presented from ProfileView when a task row is tapped, or deep-linked
/// from a notification (kind="task", taskId set).
struct TaskDetailSheet: View {
    let task: TaskItem
    let child: ChildProfile
    var onClose: () -> Void = {}
    var onApprove: () -> Void = {}
    var onRedo: () -> Void = {}
    var onEdit: () -> Void = {}

    @State private var activePhotoIndex: Int = 0

    private var stateMeta: (label: String, tone: Color, bg: Color) {
        switch task.state {
        case .done:
            return ("Approved", EvlinAddPalette.doneTone, EvlinAddPalette.doneBg)
        case .bypassed:
            return ("Bypassed", EvlinAddPalette.bypassedTone, EvlinAddPalette.bypassedBg)
        case .review:
            return ("Awaiting your review", EvlinAddPalette.reviewTone, EvlinAddPalette.reviewBg)
        case .overdue:
            return ("Overdue · not submitted", EvlinAddPalette.overdueTone, EvlinAddPalette.overdueBg)
        case .bypass:
            return ("Bypass requested", EvlinAddPalette.bypassTone, EvlinAddPalette.bypass.opacity(0.10))
        case .pending:
            return ("Waiting on student", Color.evOnSurfaceVariant, Color.evSurfaceContainerLow)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleBlock
                    statusBanner
                    whatToDoBlock
                    if task.state != .bypass {
                        submissionBlock
                    }
                    noteBlock
                    actionButtons
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
        }
        .background(Color.evSurface)
        .navigationBarBackButtonHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.clear)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.name.uppercased())
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Text("Task")
                    .font(.custom("Manrope", size: 19).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.evOnSurface)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.evSurface
                .overlay(
                    Rectangle()
                        .fill(Color.evOutlineVariant)
                        .frame(height: 1),
                    alignment: .bottom
                )
                .ignoresSafeArea(edges: .top)
        )
    }

    private var titleBlock: some View {
        Text(task.title)
            .font(.custom("Manrope", size: 26).weight(.heavy))
            .tracking(-0.5)
            .foregroundStyle(Color.evOnSurface)
            .lineSpacing(2)
            .padding(.top, 12)
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateMeta.tone)
                .frame(width: 8, height: 8)
                .shadow(color: stateMeta.tone.opacity(0.4), radius: 4)
            Text(stateMeta.label)
                .font(.custom("Inter", size: 12).weight(.heavy))
                .foregroundStyle(stateMeta.tone)
            Spacer()
            if let due = task.dueLabel {
                Text("Due \(due)")
                    .font(.custom("Inter", size: 11))
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(stateMeta.bg)
        )
    }

    private var whatToDoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT TO DO")
                .font(.custom("Inter", size: 11).weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(task.description ?? "")
                .font(.custom("Inter", size: 15))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(4)
        }
    }

    @ViewBuilder
    private var submissionBlock: some View {
        EmptyView()  // Filled in Task 2.2
    }

    @ViewBuilder
    private var noteBlock: some View {
        EmptyView()  // Filled in Task 2.3
    }

    @ViewBuilder
    private var actionButtons: some View {
        EmptyView()  // Filled in Task 2.4
    }
}

#Preview("Review (with photos)") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .review })!,
        child: .liam
    )
}

#Preview("Bypass") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .bypass })!,
        child: .liam
    )
}

#Preview("Overdue") {
    TaskDetailSheet(
        task: ProfileMockData.tasks(for: "liam").first(where: { $0.state == .overdue })!,
        child: .liam
    )
}
