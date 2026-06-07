import SwiftUI
import Combine

struct CalendarView: View {
    @State private var selectedDate: Date = Date()
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil
    @State private var activeEvent: CalendarEvent? = nil
    @State private var newEvent: PendingNewEvent? = nil
    @State private var now: Date = Date()

    private struct PendingNewEvent: Equatable {
        let event: CalendarEvent
        let person: CalendarPerson
    }

    private let calendar = Calendar.current
    private let nowTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let totalHeight: CGFloat = CGFloat(CalendarMockData.END_H) * CalendarMockData.HOUR_H

    private var events: [CalendarEvent] { CalendarMockData.events(for: selectedDate) }
    private var visibleEvents: [CalendarEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.col == focusPerson }
    }
    private var allDayItems: [AllDayItem] { CalendarMockData.allDay(for: selectedDate) }
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
                    person: CalendarMockData.person(event.col),
                    dayLabel: "\(isViewingToday ? "Today" : CalendarMockData.shortDateLabel(selectedDate)), \(event.start) – \(event.end)",
                    onClose: { activeEvent = nil },
                    onSave: { updated, extras in
                        let offset = CalendarMockData.daysFromToday(to: selectedDate)
                        var todays = CalendarMockData.runtimeEventsByOffset[offset] ?? []
                        if let i = todays.firstIndex(where: { $0.id == updated.id }) {
                            todays[i] = updated
                        } else {
                            todays.append(updated)
                        }
                        for rid in extras {
                            var copy = updated
                            copy.col = rid
                            todays.append(copy)
                        }
                        CalendarMockData.runtimeEventsByOffset[offset] = todays
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
                    dayLabel: CalendarMockData.shortDateLabel(selectedDate),
                    isNew: true,
                    onClose: { newEvent = nil },
                    onSave: { created, extras in
                        let offset = CalendarMockData.daysFromToday(to: selectedDate)
                        var todays = CalendarMockData.runtimeEventsByOffset[offset] ?? []
                        todays.append(created)
                        for rid in extras {
                            var copy = created
                            copy.col = rid
                            todays.append(copy)
                        }
                        CalendarMockData.runtimeEventsByOffset[offset] = todays
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

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTopBar
            avatarRow
            Rectangle().fill(Color.evOutlineVariant.opacity(0.4)).frame(height: 1)
            timelineBody
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
            ForEach(CalendarMockData.people) { p in
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
                            url: urlFor(p.id),
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

    private func urlFor(_ personId: String) -> String? {
        switch personId {
        case "liam": return ChildProfile.previewLiam.avatarURL
        case "maya": return ChildProfile.previewMaya.avatarURL
        case "emma": return ChildProfile.previewEmma.avatarURL
        default: return nil
        }
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
                        let normalColW = totalW / CGFloat(CalendarMockData.people.count)

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
                        ForEach(Array(CalendarMockData.people.enumerated()), id: \.element.id) { colIdx, person in
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
                let p = CalendarMockData.person(item.col)
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
        let person = CalendarMockData.person(personId)
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
        newEvent = PendingNewEvent(event: event, person: person)
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
    CalendarView()
}
