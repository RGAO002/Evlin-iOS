import SwiftUI

struct EventDetailCard: View {
    let event: CalendarEvent
    let person: CalendarPerson
    let dayLabel: String
    var isNew: Bool = false
    var onClose: () -> Void = {}
    var onSave: (CalendarEvent) -> Void = { _ in }
    var onDelete: () -> Void = {}

    @State private var isEditing: Bool
    @State private var draft: CalendarEvent
    @State private var reminderOn: Bool = true

    init(event: CalendarEvent,
         person: CalendarPerson,
         dayLabel: String,
         isNew: Bool = false,
         onClose: @escaping () -> Void = {},
         onSave: @escaping (CalendarEvent) -> Void = { _ in },
         onDelete: @escaping () -> Void = {}) {
        self.event = event
        self.person = person
        self.dayLabel = dayLabel
        self.isNew = isNew
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isNew)
        _draft = State(initialValue: event)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Card — content-hugged height (no Spacer), natural width
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 12)

                Divider()

                if isEditing {
                    editForm
                } else {
                    readView
                }

                footer
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .shadow(color: .black.opacity(0.18), radius: 40, x: 0, y: 12)
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.evPrimary)
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? (isNew ? "New event" : "Edit event") : event.title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.evPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(dayLabel)
                    .font(.custom("Inter", size: 12))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.evSurfaceContainerHigh))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Read view

    private var readView: some View {
        VStack(alignment: .leading, spacing: 0) {
            personRow
            Divider()
            categoryRow
            Divider()
            recurrenceRow
            Divider()
            noteRow
            Divider()
            locationRow
            Divider()
            reminderRow
        }
    }

    private var recurrenceRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "repeat")
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 20)
            Text(recurrenceLabel(event.recurrence))
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func recurrenceLabel(_ value: String) -> String {
        switch value {
        case "daily":    return "Every day"
        case "weekdays": return "Every weekday"
        case "weekly":   return "Every week"
        case "monthly":  return "Every month"
        default:         return "Does not repeat"
        }
    }

    // MARK: - Edit form

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            evField("TITLE") {
                TextField("Event title", text: $draft.title).evlinFormInput()
            }
            evField("TIME") {
                HStack(spacing: 8) {
                    TextField("Start", text: $draft.start).evlinFormInput()
                    Text("–").foregroundStyle(Color.evOnSurfaceVariant)
                    TextField("End", text: $draft.end).evlinFormInput()
                }
            }
            evField("CATEGORY") {
                FormPillSelector(
                    items: [("Activity", "Activity"), ("Lesson", "Lesson"),
                            ("Sport", "Sport"), ("Family", "Family"),
                            ("Routine", "Routine"), ("Study", "Study")],
                    selected: Binding(get: { draft.category }, set: { draft.category = $0 })
                )
            }
            evField("REPEAT") {
                FormPillSelector(
                    items: [("none", "Once"), ("daily", "Daily"),
                            ("weekdays", "Weekdays"), ("weekly", "Weekly")],
                    selected: Binding(get: { draft.recurrence }, set: { draft.recurrence = $0 })
                )
            }
            evField("NOTE") {
                TextField("Add a note…", text: Binding(
                    get: { draft.note },
                    set: { draft.note = $0 }
                ), axis: .vertical)
                .lineLimit(3...5)
                .evlinFormInput()
            }
            evField("LOCATION") {
                TextField("Add location…", text: Binding(
                    get: { draft.location },
                    set: { draft.location = $0 }
                ))
                .evlinFormInput()
            }
        }
        .padding(.vertical, 4)
    }

    private func evField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Color.evOnSurfaceVariant)
            content()
        }
    }

    // MARK: - Rows (consistent vertical rhythm)

    private var personRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinAvatarView(url: avatarURLFor(person.id), name: person.name, size: 26, ring: true, ringColor: person.color)
            Text(person.name)
                .font(.custom("Manrope", size: 14).weight(.heavy))
                .foregroundStyle(Color.evPrimary)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var categoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            EvlinPill(text: event.category, tone: .neutral, size: .sm)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var noteRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
                .padding(.top, 2)
            Text(event.note)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text(event.location)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var reminderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text("30 minutes before")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
            Toggle("", isOn: $reminderOn)
                .labelsHidden()
                .tint(Color.evSecondary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var canSaveDraft: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if isEditing {
                Button {
                    if isNew {
                        onClose()
                    } else {
                        draft = event
                        isEditing = false
                    }
                } label: {
                    Text(isNew ? "Discard" : "Cancel")
                        .font(.custom("Manrope", size: 18).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    onSave(draft)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isNew ? "plus" : "checkmark")
                            .font(.system(size: 15, weight: .bold))
                        Text(isNew ? "Create" : "Save")
                            .font(.custom("Manrope", size: 18).weight(.heavy))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(canSaveDraft ? Color.evPrimary : Color.evPrimary.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSaveDraft)
            } else {
                Button { onClose() } label: {
                    Text("Close")
                        .font(.custom("Manrope", size: 18).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    draft = event
                    isEditing = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .bold))
                        Text("Edit")
                            .font(.custom("Manrope", size: 18).weight(.heavy))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.evPrimary)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func avatarURLFor(_ id: String) -> String? {
        switch id {
        case "liam": return ChildProfile.liam.avatarURL
        case "maya": return ChildProfile.maya.avatarURL
        case "emma": return ChildProfile.emma.avatarURL
        default:     return nil
        }
    }
}

#Preview {
    let sample = CalendarMockData.eventsByOffset[0]?.first ?? CalendarEvent(
        col: "liam", title: "Preview", emoji: "📌",
        start: "10:00 AM", end: "11:00 AM",
        category: "Study", location: "Study Room",
        note: "Preview note text."
    )
    return EventDetailCard(
        event: sample,
        person: CalendarMockData.person(sample.col),
        dayLabel: "Today, \(sample.start) – \(sample.end)"
    )
}
