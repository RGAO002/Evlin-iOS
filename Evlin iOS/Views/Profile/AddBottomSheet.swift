import SwiftUI

/// Bottom sheet host that picks between AddMenu / AddTaskForm / AddRuleForm /
/// AddCalendarForm / AddDeviceForm. Mode switches as the user navigates.
/// See HTML 1152-1166.
struct AddBottomSheet: View {
    @Binding var mode: AddBottomMode?
    let child: ChildProfile
    var onCreateTask: (TaskItem) -> Void = { _ in }
    var onCreateRule: (RuleItem) -> Void = { _ in }
    var onCreateCalendar: (CalendarEvent) -> Void = { _ in }
    var onCreateDevice: (DeviceItem) -> Void = { _ in }

    var body: some View {
        Group {
            switch mode {
            case .menu:     AddMenu(child: child, mode: $mode)
            case .task:     AddTaskForm(child: child, onSave: onCreateTask, onCancel: { mode = nil })
            case .rule:     AddRuleForm(child: child, onSave: onCreateRule, onCancel: { mode = nil })
            case .calendar: AddCalendarForm(child: child, onSave: onCreateCalendar, onCancel: { mode = nil })
            case .device:   AddDeviceForm(child: child, onSave: onCreateDevice, onCancel: { mode = nil })
            case nil:       EmptyView()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

enum AddBottomMode: Hashable {
    case menu, task, rule, calendar, device
}

extension AddBottomMode: Identifiable {
    var id: Self { self }
}

/// 4-option launcher. HTML 1168-1192.
private struct AddMenu: View {
    let child: ChildProfile
    @Binding var mode: AddBottomMode?

    private struct Option {
        let id: AddBottomMode
        let icon: String
        let label: String
        let sub: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add new")
                .font(.custom("Manrope", size: 18).weight(.heavy))
                .tracking(-0.18)
                .foregroundStyle(Color.evPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { idx, o in
                    Button {
                        mode = o.id
                    } label: {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.evSurfaceContainerLow)
                                Image(systemName: o.icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(Color.evPrimary)
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.label)
                                    .font(.custom("Manrope", size: 16).weight(.heavy))
                                    .foregroundStyle(Color.evOnSurface)
                                Text(o.sub)
                                    .font(.custom("Inter", size: 12))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.evOutline)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if idx < options.count - 1 {
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .padding(.leading, 80)
                    }
                }
            }

            Spacer()
        }
    }

    private var options: [Option] {
        [
            .init(id: .task, icon: "checkmark.circle", label: "Add Task",
                  sub: "New chore or homework for \(child.name)"),
            .init(id: .calendar, icon: "calendar", label: "Add to Calendar",
                  sub: "Schedule something on \(child.name)'s day"),
            .init(id: .rule, icon: "shield", label: "Add Rule",
                  sub: "New screen-time or routine rule"),
            .init(id: .device, icon: "iphone", label: "Add Device",
                  sub: "Enroll a phone, tablet, or laptop"),
        ]
    }
}

// Stubs for forms — actual implementations come in Phases 6-9.
struct AddTaskForm: View {
    let child: ChildProfile
    var onSave: (TaskItem) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var category: TaskCategory = .chore
    @State private var taskDescription: String = ""
    @State private var dueLabel: String = ""

    private let categories: [(value: TaskCategory, label: String)] = [
        (.chore, "Chore"),
        (.homework, "Homework"),
        (.reading, "Reading"),
        (.routine, "Routine"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "New Task",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Read for 20 minutes", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }

            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }

            FormField(label: "What to do") {
                TextField("Instructions for the student…", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...6)
                    .evlinFormInput()
            }

            FormField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM — leave blank for no deadline", text: $dueLabel)
                    .evlinFormInput()
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextId = (Date().timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1_000_000)
        let task = TaskItem(
            id: Int(nextId),
            title: trimmed,
            state: .pending,
            iconSystemName: nil,
            category: category.rawValue,
            description: taskDescription.trimmingCharacters(in: .whitespaces),
            photos: [],
            note: nil,
            submittedAt: nil,
            dueLabel: dueLabel.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : dueLabel.trimmingCharacters(in: .whitespaces)
        )
        onSave(task)
    }
}

enum TaskCategory: String, Hashable, CaseIterable {
    case chore = "Chore"
    case homework = "Homework"
    case reading = "Reading"
    case routine = "Routine"
}
struct EditTaskForm: View {
    let task: TaskItem
    var onSave: (TaskItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var category: TaskCategory
    @State private var taskDescription: String
    @State private var dueLabel: String

    init(task: TaskItem,
         onSave: @escaping (TaskItem) -> Void,
         onDelete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.task = task
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _category = State(initialValue: TaskCategory(rawValue: task.category ?? "Chore") ?? .chore)
        _taskDescription = State(initialValue: task.description ?? "")
        _dueLabel = State(initialValue: task.dueLabel ?? "")
    }

    private let categories: [(value: TaskCategory, label: String)] = [
        (.chore, "Chore"),
        (.homework, "Homework"),
        (.reading, "Reading"),
        (.routine, "Routine"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Edit Task",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Read for 20 minutes", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }
            FormField(label: "What to do") {
                TextField("Instructions for the student…", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...6)
                    .evlinFormInput()
            }
            FormField(label: "Due (optional)") {
                TextField("e.g. Today, 6:00 PM — leave blank for no deadline", text: $dueLabel)
                    .evlinFormInput()
            }

            Button(action: onDelete) {
                Text("Delete task")
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.evError.opacity(0.4), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private func save() {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.category = category.rawValue
        updated.description = taskDescription.trimmingCharacters(in: .whitespaces)
        let trimDue = dueLabel.trimmingCharacters(in: .whitespaces)
        updated.dueLabel = trimDue.isEmpty ? nil : trimDue
        onSave(updated)
    }
}
struct AddRuleForm: View {
    let child: ChildProfile
    var onSave: (RuleItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "New Rule", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddRuleForm — implemented in Phase 7")
        }
    }
}
struct EditRuleForm: View {
    let rule: RuleItem
    var onSave: (RuleItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Edit Rule", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("EditRuleForm — implemented in Phase 7")
        }
    }
}
struct AddCalendarForm: View {
    let child: ChildProfile
    var onSave: (CalendarEvent) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Add to Calendar", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddCalendarForm — implemented in Phase 8")
        }
    }
}
struct AddDeviceForm: View {
    let child: ChildProfile
    var onSave: (DeviceItem) -> Void
    var onCancel: () -> Void
    var body: some View {
        FormShell(title: "Enroll Device", canSave: false, onCancel: onCancel, onSave: {}) {
            Text("AddDeviceForm — implemented in Phase 9")
        }
    }
}
