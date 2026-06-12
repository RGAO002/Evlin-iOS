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
        // Hosted inside `EvlinSheetCard`, so no system sheet sizing is
        // needed — the wrapper handles backdrop, height, and dismiss.
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
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
            .padding(.bottom, 12)
        }
    }

    private var options: [Option] {
        [
            .init(id: .task, icon: "checkmark.circle", label: "Add Task",
                  sub: "New chore or homework for \(child.name)"),
            .init(id: .rule, icon: "shield", label: "Add Rule",
                  sub: "New screen-time or routine rule"),
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
                            .strokeBorder(Color.evError.opacity(0.4), lineWidth: 1)
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

    @State private var title: String = ""
    @State private var detail: String = ""
    @State private var icon: String = "shield"
    @State private var tone: RuleRow.Tone = .primary

    private let icons = ["shield", "display", "moon", "sun.max", "iphone.slash", "nosign", "clock"]
    private let tones: [(value: RuleRow.Tone, label: String)] = [
        (.primary, "Primary"),
        (.tertiary, "Calm"),
        (.neutral, "Neutral"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "New Rule",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. No phones at dinner", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Detail") {
                TextField("e.g. 6:00 – 7:00 PM", text: $detail)
                    .evlinFormInput()
            }
            FormField(label: "Icon") {
                FlowLayout(spacing: 8) {
                    ForEach(icons, id: \.self) { name in
                        Button {
                            icon = name
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(icon == name ? Color.evPrimary : Color.evOnSurfaceVariant)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(icon == name ? Color.evPrimary.opacity(0.06) : Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(icon == name ? Color.evPrimary : Color.evOutlineVariant,
                                                      lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            FormField(label: "Tone") {
                FormPillSelector(items: tones, selected: $tone)
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = "rule_\(Int(Date().timeIntervalSince1970 * 1000))"
        let rule = RuleItem(
            id: id,
            iconSystemName: icon,
            title: trimmed,
            detail: detail.trimmingCharacters(in: .whitespaces),
            on: true,
            tone: tone
        )
        onSave(rule)
    }
}
struct EditRuleForm: View {
    let rule: RuleItem
    var onSave: (RuleItem) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var detail: String
    @State private var icon: String
    @State private var tone: RuleRow.Tone

    init(rule: RuleItem,
         onSave: @escaping (RuleItem) -> Void,
         onDelete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.rule = rule
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: rule.title)
        _detail = State(initialValue: rule.detail)
        _icon = State(initialValue: rule.iconSystemName)
        _tone = State(initialValue: rule.tone)
    }

    private let icons = ["shield", "display", "moon", "sun.max", "iphone.slash", "nosign", "clock"]
    private let tones: [(value: RuleRow.Tone, label: String)] = [
        (.primary, "Primary"),
        (.tertiary, "Calm"),
        (.neutral, "Neutral"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Edit Rule",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. No phones at dinner", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Detail") {
                TextField("e.g. 6:00 – 7:00 PM", text: $detail).evlinFormInput()
            }
            FormField(label: "Icon") {
                FlowLayout(spacing: 8) {
                    ForEach(icons, id: \.self) { name in
                        Button { icon = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(icon == name ? Color.evPrimary : Color.evOnSurfaceVariant)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(icon == name ? Color.evPrimary.opacity(0.06) : Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(icon == name ? Color.evPrimary : Color.evOutlineVariant,
                                                      lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            FormField(label: "Tone") {
                FormPillSelector(items: tones, selected: $tone)
            }
            Button(action: onDelete) {
                Text("Delete rule")
                    .font(.custom("Inter", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.evError.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private func save() {
        var updated = rule
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.detail = detail.trimmingCharacters(in: .whitespaces)
        updated.iconSystemName = icon
        updated.tone = tone
        onSave(updated)
    }
}
struct AddCalendarForm: View {
    let child: ChildProfile
    var onSave: (CalendarEvent) -> Void
    var onCancel: () -> Void

    @State private var title: String = ""
    @State private var startTime: String = "04:00 PM"
    @State private var endTime: String = "05:00 PM"
    @State private var category: String = "Activity"
    @State private var recurrence: String = "none"

    private let categories: [(value: String, label: String)] = [
        ("Activity", "Activity"), ("Lesson", "Lesson"), ("Sport", "Sport"),
        ("Family", "Family"), ("Routine", "Routine"), ("Study", "Study"),
    ]
    private let repeats: [(value: String, label: String)] = [
        ("none", "Once"), ("daily", "Daily"),
        ("weekdays", "Weekdays"), ("weekly", "Weekly"),
    ]

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Add to Calendar",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Title") {
                TextField("e.g. Soccer Practice", text: $title)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Time") {
                HStack(spacing: 8) {
                    TextField("Start", text: $startTime).evlinFormInput()
                    Text("–").foregroundStyle(Color.evOnSurfaceVariant)
                    TextField("End", text: $endTime).evlinFormInput()
                }
            }
            FormField(label: "Category") {
                FormPillSelector(items: categories, selected: $category)
            }
            FormField(label: "Repeat") {
                FormPillSelector(items: repeats, selected: $recurrence)
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let event = CalendarEvent(
            col: child.id,
            title: trimmed,
            emoji: emojiFor(category),
            start: startTime,
            end: endTime,
            category: category,
            location: "",
            note: "",
            recurrence: recurrence
        )
        onSave(event)
    }

    private func emojiFor(_ cat: String) -> String {
        switch cat {
        case "Activity": return "📅"
        case "Lesson":   return "📚"
        case "Sport":    return "⚽"
        case "Family":   return "🏠"
        case "Routine":  return "🌙"
        case "Study":    return "📐"
        default:         return "🗓️"
        }
    }
}
struct AddDeviceForm: View {
    let child: ChildProfile
    var onSave: (DeviceItem) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var detail: String = ""
    @State private var iconSystemName: String = "iphone"

    private struct DeviceType: Hashable {
        let icon: String
        let label: String
    }
    private let types: [DeviceType] = [
        .init(icon: "iphone",          label: "Phone"),
        .init(icon: "ipad",            label: "Tablet"),
        .init(icon: "laptopcomputer",  label: "Laptop"),
        .init(icon: "desktopcomputer", label: "Desktop"),
        .init(icon: "applewatch",      label: "Watch"),
        .init(icon: "tv",              label: "TV"),
    ]

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(
            title: "Enroll Device",
            canSave: canSave,
            onCancel: onCancel,
            onSave: save
        ) {
            FormField(label: "Device type") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(types, id: \.icon) { t in
                        Button {
                            iconSystemName = t.icon
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: t.icon)
                                    .font(.system(size: 24, weight: .medium))
                                Text(t.label)
                                    .font(.custom("Inter", size: 11).weight(.heavy))
                            }
                            .foregroundStyle(iconSystemName == t.icon ? Color.evPrimary : Color.evOnSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(iconSystemName == t.icon ? Color.evPrimary.opacity(0.06) : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(iconSystemName == t.icon ? Color.evPrimary : Color.evOutlineVariant,
                                            lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            FormField(label: "Name") {
                TextField("e.g. iPhone 15", text: $name)
                    .font(.custom("Inter", size: 14).weight(.semibold))
                    .evlinFormInput()
            }
            FormField(label: "Notes") {
                TextField("e.g. \(child.name)'s primary phone", text: $detail)
                    .evlinFormInput()
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let device = DeviceItem(
            iconSystemName: iconSystemName,
            name: trimmed,
            detail: detail.trimmingCharacters(in: .whitespaces),
            locked: false
        )
        onSave(device)
    }
}
