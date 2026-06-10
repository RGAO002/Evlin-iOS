import SwiftUI
import Combine

struct CalendarView: View {
    @Environment(FamilyStore.self) private var familyStore
    @ObservedObject var store: CalendarStore

    @State private var selectedDate: Date = Date()
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil
    @State private var activeEvent: CalendarEvent? = nil
    @State private var newEvent: PendingNewEvent? = nil
    @State private var now: Date = Date()

    /// Real people columns: a synthetic "family" pseudo-person first, then the
    /// live FamilyStore children. Replaces the retired `CalendarMockData.people`.
    private var people: [CalendarPerson] {
        CalendarStore.people(from: familyStore.childProfiles)
    }

    /// Look up a person column by id, falling back to the family pseudo-person
    /// (or a synthetic family stand-in if the list is somehow empty).
    private func person(_ id: String) -> CalendarPerson {
        people.first(where: { $0.id == id }) ?? people.first ?? CalendarPerson(
            id: "family", name: "Family events",
            color: .evPrimary, bg: .evSurfaceContainerHigh)
    }

    private struct PendingNewEvent: Equatable {
        let event: CalendarEvent
        let person: CalendarPerson
    }

    private let calendar = Calendar.current
    private let nowTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let totalHeight: CGFloat = CGFloat(CalendarMockData.END_H) * CalendarMockData.HOUR_H

    /// Store events with unknown columns remapped to "family" (CAL-5).
    /// Computed against the LIVE people list on every render, so an event
    /// whose child column was deleted/unpaired stays visible in the family
    /// lane instead of silently vanishing from the grid.
    private var events: [CalendarEvent] {
        CalendarStore.remapOrphanColumns(store.events, knownCols: Set(people.map(\.id)))
    }
    private var visibleEvents: [CalendarEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.col == focusPerson }
    }
    private var allDayItems: [AllDayItem] { store.allDayItems }
    private var isViewingToday: Bool { calendar.isDateInToday(selectedDate) }

    /// All-day pills shown above the timeline. In focus mode we hide
    /// pills that don't belong to the focused person — matches the
    /// design's grid-per-column layout (only the focused column slot
    /// renders).
    private var visibleAllDayItems: [AllDayItem] {
        guard let focusPerson else { return allDayItems }
        return allDayItems.filter { $0.col == focusPerson }
    }

    /// Shared animation curve for focus enter/exit. Mirrors the
    /// design's "events expand outward, push others out" intent —
    /// non-bouncy ease so the motion reads as a deliberate column
    /// resize rather than a spring. Reuse the exact same curve in
    /// every tap-handler so the reverse animation is symmetric.
    private static let focusAnim: Animation = .easeInOut(duration: 0.32)

    var body: some View {
        VStack(spacing: 0) {
            outerDayNav
            ZStack(alignment: .bottomTrailing) {
                scrollContainer
                floatingAddButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(selectedDate: $selectedDate, onClose: { showMonthPicker = false })
        }
        .overlay {
            if let event = activeEvent {
                EventDetailCard(
                    event: event,
                    person: person(event.col),
                    people: people,
                    dayLabel: "\(isViewingToday ? "Today" : CalendarMockData.shortDateLabel(selectedDate)), \(event.start) – \(event.end)",
                    onClose: { activeEvent = nil },
                    onSave: { updated, extras in
                        persistSave(updated, extras: extras, isNew: false)
                        activeEvent = nil
                    },
                    onDelete: {
                        let target = selectedDate
                        if let backendID = event.backendID {
                            Task { await store.delete(id: backendID, refetchFor: target) }
                        }
                        activeEvent = nil
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }
            if let pending = newEvent {
                EventDetailCard(
                    event: pending.event,
                    person: pending.person,
                    people: people,
                    dayLabel: CalendarMockData.shortDateLabel(selectedDate),
                    isNew: true,
                    onClose: { newEvent = nil },
                    onSave: { created, extras in
                        persistSave(created, extras: extras, isNew: true)
                        newEvent = nil
                    }
                )
                .transition(.opacity)
                .zIndex(101)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeEvent)
        .animation(.easeInOut(duration: 0.2), value: newEvent)
        .onReceive(nowTimer) { t in now = t }
        // Re-runs on first appearance AND whenever the viewed day changes,
        // covering both initial load and day navigation.
        .task(id: selectedDate) { await store.load(for: selectedDate) }
        .refreshable { await store.load(for: selectedDate) }
        .alert("Calendar", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    /// Convert an edited event's wall-clock string times (interpreted on the
    /// viewed day, in the event's own timezone — device timezone only for new
    /// events) into UTC ISO, build the participants from the chosen columns,
    /// and call the store (create or update). The store re-fetches the window
    /// on success so the grid reflects the server.
    private func persistSave(_ ev: CalendarEvent, extras: [String], isNew: Bool) {
        // EventDetailCard.commitSave passes the FULL recipient selection
        // (seeded from the event's participantCols): the primary as `ev.col`
        // plus every other selected recipient in `extras`. Building the PUT
        // participants from this complete set means an untouched edit
        // round-trips all participants instead of hard-deleting the rows of
        // children whose column wasn't tapped.
        let cols = [ev.col] + extras
        // UPDATE must stay in the event's stored timezone — display times were
        // rendered in it, so re-encoding them in a different device timezone
        // would silently shift the stored UTC instant. Only NEW events (and
        // legacy rows with no timezone) adopt the current device timezone.
        let tz = (isNew ? nil : ev.timezone) ?? TimeZone.current.identifier
        let startISO = CalendarTimeWire.utcISO(
            wallClock: ev.start, onDay: selectedDate, timezoneID: tz)
        let endISO = CalendarTimeWire.utcISO(
            wallClock: ev.end, onDay: selectedDate, timezoneID: tz)
        let parts = CalendarTimeWire.participants(fromColumns: cols)
        let target = selectedDate
        if isNew {
            let body = CalendarEventCreateBody(
                title: ev.title, emoji: ev.emoji, category: ev.category,
                location: ev.location, note: ev.note, all_day: false,
                start_at: startISO, end_at: endISO, timezone: tz,
                recurrence_type: ev.recurrence, recurrence_until: nil,
                participants: parts)
            Task { await store.create(body, refetchFor: target) }
        } else if let backendID = ev.backendID {
            let body = CalendarEventUpdateBody(
                title: ev.title, emoji: ev.emoji, category: ev.category,
                location: ev.location, note: ev.note, all_day: false,
                start_at: startISO, end_at: endISO, timezone: tz,
                recurrence_type: ev.recurrence, recurrence_until: nil,
                participants: parts)
            Task { await store.update(id: backendID, body, refetchFor: target) }
        }
    }

    private var outerDayNav: some View {
        HStack {
            navSquareButton(systemName: "chevron.left") {
                if let d = calendar.date(byAdding: .day, value: -1, to: selectedDate) {
                    selectedDate = d
                }
            }

            Spacer()

            Button {
                showMonthPicker = true
            } label: {
                VStack(spacing: 2) {
                    Text(CalendarMockData.shortDateLabel(selectedDate))
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .tracking(-0.25)
                        .foregroundStyle(Color.evPrimary)
                    Text("TAP TO CHANGE DATE")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            navSquareButton(systemName: "chevron.right") {
                if let d = calendar.date(byAdding: .day, value: 1, to: selectedDate) {
                    selectedDate = d
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Color.evSurfaceContainerLow
                .ignoresSafeArea(edges: .top)
        )
    }

    private func navSquareButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.evPrimary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.evSurfaceContainerLowest)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var scrollContainer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                cardContent
                    .id("timeline")
            }
            .onAppear { scrollToFirstEvent(proxy) }
            .onChange(of: selectedDate) { _, _ in scrollToFirstEvent(proxy) }
            // Only auto-scroll when ENTERING focus (someone got selected).
            // Exiting focus — old == non-nil, new == nil — should keep the
            // current scroll position so the parent doesn't get yanked to
            // a different y-offset just because they tapped the return
            // button.
            .onChange(of: focusPerson) { old, new in
                guard new != nil, new != old else { return }
                scrollToFirstEvent(proxy)
            }
        }
    }

    /// True while the day has nothing to draw — placeholders only ever
    /// replace an EMPTY timeline; once events exist they stay on screen
    /// through reloads/failures (the store keeps the last good list).
    private var hasNoEvents: Bool { events.isEmpty && allDayItems.isEmpty }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTopBar
            avatarRow
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1)
            // CAL-4: surface fetch state instead of rendering a failed or
            // in-flight load as an innocent empty day. Load errors stay
            // inline here — `lastError`/the alert is reserved for mutations.
            if store.state == .loading && hasNoEvents {
                loadingPlaceholder
            } else if case .failed(let message) = store.state, hasNoEvents {
                failedPlaceholder(message)
            } else {
                timelineBody
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .evShadow(.ambient)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .padding(.bottom, 80)
    }

    // MARK: - Fetch-state placeholders (CAL-4)

    /// Shown while the FIRST load of a day is in flight (no cached events).
    /// Mirrors the `HomeChildrenEmptyState` informative-placeholder pattern.
    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView("Loading events…")
                .font(.custom("Inter", size: 13))
                .tint(Color.evPrimary)
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 20)
    }

    /// Shown when the day's fetch failed and there is nothing cached to draw —
    /// an honest inline error instead of an innocent empty day. "Try Again"
    /// re-runs the same window fetch.
    private func failedPlaceholder(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.evOutline)
            Text("Couldn't load events")
                .font(.custom("Manrope", size: 15).weight(.bold))
                .foregroundStyle(Color.evOnSurface)
            Text(message)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Button {
                Task { await store.load(for: selectedDate) }
            } label: {
                Text("Try Again")
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.evPrimary))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    private var cardTopBar: some View {
        HStack {
            Text("Today's Events")
                .font(.custom("Manrope", size: 17).weight(.heavy))
                .foregroundStyle(Color.evPrimary)

            Spacer()

            HStack(spacing: 2) {
                topBarButton(systemName: "chevron.left") {
                    if let d = calendar.date(byAdding: .day, value: -1, to: selectedDate) {
                        selectedDate = d
                    }
                }
                topBarButton(systemName: "calendar") { showMonthPicker = true }
                topBarButton(systemName: "chevron.right") {
                    if let d = calendar.date(byAdding: .day, value: 1, to: selectedDate) {
                        selectedDate = d
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func topBarButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var avatarRow: some View {
        HStack(spacing: 0) {
            // Time-gutter slot — empty in normal mode; in focus mode
            // surfaces a "people" return button that exits focus. The
            // button conditionally renders with .transition so it
            // fades + scales in/out alongside the column animation.
            ZStack {
                if focusPerson != nil {
                    Button {
                        withAnimation(Self.focusAnim) { focusPerson = nil }
                    } label: {
                        // Matches design jsx line 542-548:
                        //   width 28, height 28, radius 9,
                        //   surfaceContainerHigh bg, primary icon,
                        //   Material "group" (3-person) glyph.
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.evPrimary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.evSurfaceContainerHigh)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .frame(width: CalendarMockData.TIME_W)

            // Avatars — non-focused ones collapse to 0 width + fade
            // when another avatar is focused. Keeping every avatar
            // in the hierarchy (not removed via ForEach filter) is
            // what lets SwiftUI smoothly animate the frame change
            // instead of pop-removing the views.
            ForEach(people) { p in
                let visible = focusPerson == nil || focusPerson == p.id
                avatarButton(for: p)
                    .frame(maxWidth: visible ? .infinity : 0)
                    .opacity(visible ? 1 : 0)
                    .clipped()
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func avatarButton(for p: CalendarPerson) -> some View {
        let focused = focusPerson == p.id
        Button {
            withAnimation(Self.focusAnim) {
                focusPerson = (focusPerson == p.id) ? nil : p.id
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if p.id == "family" {
                        Circle().fill(p.color)
                            .frame(width: focused ? 44 : 36, height: focused ? 44 : 36)
                        Image(systemName: "house.fill")
                            .font(.system(size: focused ? 18 : 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        EvlinAvatarView(
                            url: p.avatarURL,
                            name: p.name,
                            size: focused ? 44 : 36,
                            ring: true,
                            ringColor: p.color
                        )
                    }
                }
                .frame(width: 46, height: 46)

                Text(p.id == "family" ? "Family" : p.name)
                    .font(.custom("Inter", size: 10).weight(focused ? .heavy : .semibold))
                    .foregroundStyle(focused ? p.color : Color.evOnSurface)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !visibleAllDayItems.isEmpty {
                allDayBar
            }

            HStack(alignment: .top, spacing: 0) {
                timeGutter
                    .frame(width: CalendarMockData.TIME_W)

                ZStack(alignment: .topLeading) {
                    ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: CGFloat(h) * CalendarMockData.HOUR_H)
                    }

                    GeometryReader { geo in
                        let totalW = geo.size.width
                        let normalColW = totalW / CGFloat(max(people.count, 1))

                        // Render every person column unconditionally
                        // so SwiftUI animates frame/offset/opacity
                        // changes instead of removing-then-re-inserting
                        // views. Each column's target geometry is:
                        //   • no focus → normal grid slot
                        //   • this one focused → x=0, width=totalW
                        //     (expands outward to both edges)
                        //   • another focused → width=0 + opacity 0
                        //     (collapses in place, fades away)
                        // Column-width animation strategy: NEVER shrink
                        // a column to 0 width. SwiftUI silently drops
                        // descendants from the active render path when
                        // their ancestor frame goes to 0, and when the
                        // frame animates back the descendants don't get
                        // re-evaluated (Liam/Maya/Emma columns stayed
                        // empty after exiting focus). Instead:
                        //   • Focused column → x=0, width=totalW
                        //     (slides + expands outward to both edges)
                        //   • Every other column → stays at its natural
                        //     x = colIdx·normalColW, width = normalColW
                        //     (no layout change, just opacity 0)
                        //   • Opacity does the visual hiding; opacity 0
                        //     also disables hit testing so taps fall
                        //     through to the focused column underneath.
                        ForEach(Array(people.enumerated()), id: \.element.id) { colIdx, person in
                            let isFocused = focusPerson == person.id
                            let isAnyFocused = focusPerson != nil

                            let targetW: CGFloat = isFocused ? totalW : normalColW
                            let targetX: CGFloat = isFocused ? 0 : CGFloat(colIdx) * normalColW
                            let targetOpacity: Double = (!isAnyFocused || isFocused) ? 1.0 : 0.0

                            let colEvents = events.filter { $0.col == person.id }

                            ZStack(alignment: .topLeading) {
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .frame(width: targetW, height: totalHeight)

                                ForEach(colEvents) { ev in
                                    columnEventPill(ev, color: person.color, columnWidth: targetW)
                                        .offset(y: CalendarMockData.yFor(ev.start))
                                }
                            }
                            .frame(width: targetW, height: totalHeight, alignment: .topLeading)
                            .opacity(targetOpacity)
                            .offset(x: targetX)
                            // The focused column needs to draw OVER the
                            // others (which still occupy their normal
                            // slots underneath). zIndex 1 when focused
                            // keeps the expanded column on top during
                            // the slide-and-grow animation.
                            .zIndex(isFocused ? 1 : 0)
                        }
                    }
                    .frame(height: totalHeight)

                    if isViewingToday {
                        currentTimeIndicator
                    }
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
    }

    private var allDayBar: some View {
        HStack(spacing: 8) {
            Text("ALL DAY")
                .font(.custom("Inter", size: 10).weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.evOnSurfaceVariant)
            ForEach(visibleAllDayItems) { item in
                let p = person(item.col)
                Text(item.title)
                    .font(.custom("Inter", size: 12).weight(.semibold))
                    .foregroundStyle(p.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(p.bg))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                Text(hourLabel(h))
                    .font(.custom("Inter", size: 10).weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.evOutline)
                    .frame(height: CalendarMockData.HOUR_H, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .offset(y: -4)
            }
        }
        .frame(width: CalendarMockData.TIME_W)
    }

    private func hourLabel(_ h: Int) -> String {
        switch h {
        case 0, 24: return ""
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(h - 12) PM"
        }
    }

    private func columnEventPill(_ ev: CalendarEvent, color: Color, columnWidth: CGFloat) -> some View {
        let h = CalendarMockData.heightFor(start: ev.start, end: ev.end)
        return Button { activeEvent = ev } label: {
            VStack(alignment: .leading, spacing: 3) {
                if h > 38 {
                    Text(ev.emoji).font(.system(size: 12))
                }
                HStack(spacing: 4) {
                    if ev.recurrence != "none" {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(ev.title)
                        .font(.custom("Manrope", size: 11).weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if h > 54 {
                    Text("\(ev.start.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")) – \(ev.end.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))")
                        .font(.custom("Inter", size: 9).weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(h > 40 ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: h)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
            )
            .shadow(color: color.opacity(0.33), radius: 6, y: 1)
            .padding(.horizontal, 3)
        }
        .buttonStyle(.plain)
        .frame(width: columnWidth)
    }

    private var currentTimeIndicator: some View {
        let _ = now
        let y = CalendarMockData.yForNow()
        return ZStack(alignment: .leading) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .offset(x: -5)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
                .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: y - 5)
    }

    private var floatingAddButton: some View {
        Button { startNewEvent() } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.evPrimary))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    /// Opens the new-event sheet defaulted to the focused person (or
    /// "family" if no filter is active). The user can change/multi-select
    /// recipients inside the sheet itself.
    private func startNewEvent() {
        let personId = focusPerson ?? "family"
        let chosenPerson = person(personId)
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        let startDate = Date()
        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: addOneHour(to: startDate))
        let event = CalendarEvent(
            col: personId,
            title: "",
            emoji: "📌",
            start: startStr,
            end: endStr,
            category: "Activity",
            location: "",
            note: ""
        )
        newEvent = PendingNewEvent(event: event, person: chosenPerson)
    }

    private func addOneHour(to date: Date) -> Date {
        calendar.date(byAdding: .hour, value: 1, to: date) ?? date
    }

    private func scrollToFirstEvent(_ proxy: ScrollViewProxy) {
        guard let first = visibleEvents.map({ CalendarMockData.yFor($0.start) }).min() else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("timeline", anchor: UnitPoint(x: 0, y: max(0, first - 80) / totalHeight))
        }
    }
}

#Preview {
    CalendarView(store: CalendarStore(api: APIClient(baseURL: "http://preview.local")))
        .environment(FamilyStore(api: APIClient(baseURL: "http://preview.local")))
}
