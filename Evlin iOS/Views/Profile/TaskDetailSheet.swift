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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(child.name.uppercased())'S SUBMISSION")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                Spacer()
                if let at = task.submittedAt {
                    Text("at \(at)")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            if !task.photos.isEmpty {
                photoGallery
            } else {
                emptySubmissionPlaceholder
            }
        }
    }

    private var photoGallery: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: task.photos[min(activePhotoIndex, task.photos.count - 1)])) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.evSurfaceContainerLow)
                    }
                }
                .aspectRatio(4/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1)
                )

                if task.photos.count > 1 {
                    Text("\(activePhotoIndex + 1) / \(task.photos.count)")
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(10)
                }
            }

            if task.photos.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(task.photos.enumerated()), id: \.offset) { idx, urlStr in
                            Button {
                                activePhotoIndex = idx
                            } label: {
                                AsyncImage(url: URL(string: urlStr)) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Rectangle().fill(Color.evSurfaceContainerLow)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(idx == activePhotoIndex ? Color.evPrimary : Color.evOutlineVariant,
                                                lineWidth: idx == activePhotoIndex ? 2 : 1)
                                )
                                .opacity(idx == activePhotoIndex ? 1.0 : 0.75)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var emptySubmissionPlaceholder: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.evSurfaceContainerLow)
                    .frame(width: 56, height: 56)
                Image(systemName: task.state == .overdue ? "exclamationmark" : "hourglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            Text(task.state == .overdue ? "No photo submitted" : "Waiting for photo")
                .font(.custom("Manrope", size: 14).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text(task.state == .overdue
                 ? "\(child.name) missed the deadline"
                 : "\(child.name) hasn't uploaded yet")
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.evOutlineVariant)
        )
    }

    @ViewBuilder
    private var noteBlock: some View {
        let isBypass = task.state == .bypass
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isBypass
                     ? "WHY \(child.name.uppercased()) CAN'T DO IT"
                     : "\(child.name.uppercased())'S NOTE")
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(isBypass ? EvlinAddPalette.bypass : Color.evOnSurfaceVariant)
                Spacer()
                if isBypass, let at = task.submittedAt {
                    Text("at \(at)")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }

            if let note = task.note {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.custom("Inter", size: 14))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isBypass ? EvlinAddPalette.bypass.opacity(0.06) : Color.evSurfaceContainerLow)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isBypass ? EvlinAddPalette.bypass.opacity(0.25) : Color.evOutlineVariant,
                                    lineWidth: 1)
                    )
            } else {
                Text("No note added.")
                    .font(.custom("Inter", size: 13))
                    .italic()
                    .foregroundStyle(Color.evOutline)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch task.state {
        case .review:
            VStack(spacing: 10) {
                primaryButton("Approve submission", color: Color.evSecondary, action: onApprove)
                outlinedButton("Request redo", action: onRedo)
            }
        case .bypass:
            VStack(spacing: 10) {
                primaryButton("Allow bypass", color: EvlinAddPalette.bypass, action: onApprove)
                outlinedButton("Deny — keep as task", action: onRedo)
            }
        case .pending, .overdue:
            primaryButton("Mark as complete", color: Color.evSecondary, action: onApprove)
        case .done:
            doneStatusCard
        case .bypassed:
            bypassedStatusCard
        }
    }

    private func primaryButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .tracking(0.3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color)
                )
                .shadow(color: color.opacity(0.32), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func outlinedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.custom("Manrope", size: 12).weight(.heavy))
                .tracking(1.0)
                .foregroundStyle(Color.evOnTertiaryContainer)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: 0xEF6C00), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var doneStatusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.evSecondary)
            Text("You approved this task")
                .font(.custom("Manrope", size: 14).weight(.bold))
                .foregroundStyle(Color.evSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSecondaryContainer)
        )
    }

    private var bypassedStatusCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "nosign")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Text(task.title)
                .font(.custom("Manrope", size: 14).weight(.bold))
                .strikethrough(true, color: Color.evOnSurfaceVariant)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.evSurfaceContainerLow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.evOutlineVariant, lineWidth: 1)
        )
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
