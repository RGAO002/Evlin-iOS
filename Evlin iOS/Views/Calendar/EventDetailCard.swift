import SwiftUI

struct EventDetailCard: View {
    let event: CalendarEvent
    let person: CalendarPerson
    /// Real people columns (family + live children), injected by the caller so
    /// the recipient pills + avatar lookups show real data instead of the
    /// retired liam/maya/emma mock.
    var people: [CalendarPerson] = []
    let dayLabel: String
    var isNew: Bool = false
    var onClose: () -> Void = {}
    /// Save callback. The first arg is the primary event; the second is
    /// any extra recipient IDs the user multi-selected so the caller can
    /// fan out a copy of the event under each. For a single-recipient
    /// save the second array is empty.
    var onSave: (CalendarEvent, [String]) -> Void = { _, _ in }
    var onDelete: () -> Void = {}

    @State private var isEditing: Bool
    @State private var draft: CalendarEvent

    // Inline-pill "add new category" — HTML 1494-1502, 1566.
    /// CAL-8: custom categories persist across cards + launches as a small
    /// JSON-encoded `[String]` in UserDefaults (device-local by design —
    /// cross-device sync is explicitly out of scope until a backend field
    /// exists).
    @AppStorage("calendar.customCategories") private var customCategoriesData: Data = Data()
    @State private var addingCategory: Bool = false
    @State private var newCategoryName: String = ""
    @FocusState private var newCategoryFocused: Bool

    /// Multi-select recipients for the event. Defaults to the event's FULL
    /// backend participant set (`participantCols`), falling back to just
    /// {`event.col`} for mock/preview rows. Seeding the full set means an
    /// untouched edit round-trips every participant instead of silently
    /// dropping the other children's rows. Picking "family" is mutually
    /// exclusive with the per-child options (consistent with how the app
    /// interprets a family event).
    @State private var recipientSelection: Set<String> = []

    /// Read-mode delete confirmation gate.
    @State private var showDeleteConfirm = false

    private static let defaultCategories: [String] =
        ["Activity", "Lesson", "Sport", "Family", "Routine", "Study"]

    /// Persisted custom list, decoded on demand from the @AppStorage blob.
    private var storedCustomCategories: [String] {
        (try? JSONDecoder().decode([String].self, from: customCategoriesData)) ?? []
    }

    private func persistCustomCategories(_ list: [String]) {
        customCategoriesData = (try? JSONEncoder().encode(list)) ?? Data()
    }

    /// Defaults + persisted customs, then the event's OWN category when it's
    /// neither (CAL-8a) — e.g. a custom category created on another device —
    /// so reopening the card shows the event's category selected instead of
    /// nothing.
    private var allCategories: [String] {
        var list = Self.defaultCategories
        for c in storedCustomCategories where !list.contains(c) { list.append(c) }
        if !event.category.isEmpty && !list.contains(event.category) {
            list.append(event.category)
        }
        return list
    }

    init(event: CalendarEvent,
         person: CalendarPerson,
         people: [CalendarPerson] = [],
         dayLabel: String,
         isNew: Bool = false,
         onClose: @escaping () -> Void = {},
         onSave: @escaping (CalendarEvent, [String]) -> Void = { _, _ in },
         onDelete: @escaping () -> Void = {}) {
        self.event = event
        self.person = person
        self.people = people
        self.dayLabel = dayLabel
        self.isNew = isNew
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isNew)
        _draft = State(initialValue: event)
        _recipientSelection = State(initialValue: Set(event.participantCols ?? [event.col]))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                // Card — header + scrollable middle + footer.
                // Caps height at ~85% of the screen so the form never
                // overflows when many fields are visible (Title / Time /
                // Assigned to / Category / Repeat / Notes / Location).
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)

                    Divider()

                    ScrollView(showsIndicators: false) {
                        if isEditing {
                            editForm
                        } else {
                            readView
                        }
                    }
                    .padding(.horizontal, 20)

                    Divider()

                    footer
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .frame(maxHeight: geo.size.height * 0.86)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white)
                )
                .shadow(color: .black.opacity(0.18), radius: 40, x: 0, y: 12)
                .padding(.horizontal, 20)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.light)
        .confirmationDialog("Delete this event?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete event", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(event.title)\" for everyone it's assigned to.")
        }
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
            if event.reminderMinutesBefore != nil {
                Divider()
                reminderRow
            }
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

    /// Short labels for pill-style selector. Read-mode summary in the
    /// detail card uses these too so the page stays compact.
    private func recurrenceLabel(_ value: String) -> String {
        switch value {
        case "daily":    return "Daily"
        case "weekdays": return "Weekdays"
        case "weekly":   return "Weekly"
        case "monthly":  return "Monthly"
        default:         return "Never"
        }
    }

    // MARK: - Edit form

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            evField("TITLE") {
                TextField("Event title", text: $draft.title).evlinFormInput()
            }
            evField("TIME") {
                EventTimePicker(start: $draft.start, end: $draft.end)
            }
            evField("ASSIGNED TO") { recipientPills }
            evField("CATEGORY") { categoryPills }
            evField("REPEAT") {
                FormPillSelector(
                    items: [("none", "Never"),
                            ("daily", "Daily"),
                            ("weekdays", "Weekdays"),
                            ("weekly", "Weekly"),
                            ("monthly", "Monthly")],
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
            evField("REMINDER") {
                HStack {
                    Text("30 minutes before")
                        .font(.custom("Inter", size: 14))
                        .foregroundStyle(Color.evOnSurface)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { draft.reminderMinutesBefore != nil },
                        set: { draft.reminderMinutesBefore = $0 ? 30 : nil }
                    ))
                    .labelsHidden()
                    .tint(Color.evPrimary)
                }
                .evlinFormInput()
            }
        }
        .padding(.vertical, 4)
        // Tiny horizontal breathing room for shape-stroke pills sitting
        // flush with the ScrollView's leading edge — without this the
        // very first pill in any FlowLayout (Family / Activity / Never
        // / 30-mins-before) would lose its left/right border to the
        // clip rect.
        .padding(.horizontal, 1)
    }

    /// Pills with an inline "+" that swaps to a primary-bordered pill input
    /// in place — HTML 1564-1567. The "+" and the in-place input both
    /// reuse the exact same padding profile as a real category pill so
    /// their heights match and FlowLayout aligns everything on a single
    /// baseline.
    private var categoryPills: some View {
        FlowLayout(spacing: 6) {
            ForEach(allCategories, id: \.self) { c in
                let selected = draft.category == c
                Button {
                    draft.category = c
                } label: {
                    Text(c.uppercased())
                        .font(.custom("Inter", size: 11).weight(.heavy))
                        .tracking(0.9)
                        .foregroundStyle(selected ? Color.evPrimary : Color.evOnSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selected
                                           ? Color.evPrimary.opacity(0.08)
                                           : Color.white)
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.evPrimary : Color.evOutlineVariant,
                                                   lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }

            if addingCategory {
                // Pill-sized inline input. Same v-padding (6) and font
                // (Inter 11 heavy) as a real category pill so heights
                // match exactly. minWidth gives enough room to type
                // without the pill collapsing while the field is empty.
                TextField("Name…", text: $newCategoryName)
                    .focused($newCategoryFocused)
                    .submitLabel(.done)
                    .font(.custom("Inter", size: 11).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                    .frame(minWidth: 64, maxWidth: 120)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(Color.evPrimary, lineWidth: 2))
                    .onSubmit { commitNewCategory() }
                    .onChange(of: newCategoryFocused) { _, focused in
                        if !focused { commitNewCategory() }
                    }
            } else {
                // Original dashed-circle "+" button (per design). The
                // misalignment was purely a height mismatch — the old
                // 32×32 frame was taller than the surrounding ~26pt
                // pills, so FlowLayout's top-alignment dropped it below
                // the baseline. Sizing the circle to match the pill
                // height (font 11 + .vertical 6 padding ≈ 26pt) puts it
                // back on the same row baseline as the rest.
                Button {
                    addingCategory = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        newCategoryFocused = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.clear))
                        .overlay(
                            Circle().strokeBorder(
                                Color.evOutlineVariant,
                                style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitNewCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !allCategories.contains(trimmed) {
            persistCustomCategories(storedCustomCategories + [trimmed])
            draft.category = trimmed
        }
        newCategoryName = ""
        addingCategory = false
    }

    // MARK: - Recipients (multi-select)

    /// Single-line pill row for the editForm "Assigned to" field.
    /// Tapping any pill is always allowed; toggle handles exclusivity
    /// (picking a child auto-clears Family, picking Family clears all
    /// children). Conflicting pills are visually faded to telegraph the
    /// rule but remain tappable so the user can swap with one tap.
    private var recipientPills: some View {
        HStack(spacing: 6) {
            ForEach(people) { p in
                let isSel = recipientSelection.contains(p.id)
                let conflicting = isRecipientDisabled(p.id)
                Button {
                    toggleRecipient(p.id)
                } label: {
                    HStack(spacing: 4) {
                        recipientAvatar(for: p)
                        Text(p.id == "family" ? "Family" : p.name)
                            .font(.custom("Inter", size: 11)
                                  .weight(isSel ? .heavy : .semibold))
                            .foregroundStyle(isSel ? p.color : Color.evOnSurfaceVariant)
                            .lineLimit(1)
                        if isSel {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(p.color)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isSel
                                       ? p.color.opacity(0.10)
                                       : Color.white)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSel ? p.color : Color.evOutlineVariant,
                            lineWidth: 2
                        )
                    )
                    .opacity(conflicting ? 0.45 : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func recipientAvatar(for p: CalendarPerson) -> some View {
        if p.id == "family" {
            ZStack {
                Circle().fill(p.color)
                Image(systemName: "house.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 16, height: 16)
        } else {
            EvlinAvatarView(
                url: p.avatarURL,
                name: p.name,
                size: 16,
                ring: true,
                ringColor: p.color
            )
        }
    }

    private func toggleRecipient(_ id: String) {
        if id == "family" {
            recipientSelection = ["family"]
            return
        }
        recipientSelection.remove("family")
        if recipientSelection.contains(id) {
            recipientSelection.remove(id)
            if recipientSelection.isEmpty { recipientSelection.insert("family") }
        } else {
            recipientSelection.insert(id)
        }
    }

    private func isRecipientDisabled(_ id: String) -> Bool {
        if id == "family" {
            return recipientSelection.contains(where: { $0 != "family" })
        }
        return recipientSelection.contains("family")
    }

    /// Builds the primary saved event using the first selected recipient
    /// as `col`, then forwards any extras to the parent so it can fan
    /// out a copy under each.
    private func commitSave() {
        // Order recipients by the real people-column order (family first, then
        // children). Fall back to the selection itself if no people were
        // injected (e.g. preview), so a save still produces a valid primary.
        let order = people.isEmpty ? Array(recipientSelection) : people.map(\.id)
        let chosen = order.filter { recipientSelection.contains($0) }
        guard let primary = chosen.first else {
            onSave(draft, [])
            return
        }
        var saved = draft
        saved.col = primary
        let extras = Array(chosen.dropFirst())
        onSave(saved, extras)
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
            EvlinAvatarView(url: person.avatarURL, name: person.name, size: 26, ring: true, ringColor: person.color)
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

    /// Read-mode reminder summary. Only rendered when a reminder is set (the
    /// caller gates this on `reminderMinutesBefore != nil`), so `mins` is
    /// always non-nil here — fall back to 30 defensively. Bell icon mirrors
    /// the other read rows' leading-SF-Symbol treatment.
    private var reminderRow: some View {
        let mins = event.reminderMinutesBefore ?? 30
        return HStack(spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 16))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 24)
            Text("Reminder · \(mins) minutes before")
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
            Spacer()
        }
        .padding(.vertical, 12)
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
                    commitSave()
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
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.evError)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.evError.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)

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
