import SwiftUI
import Combine

struct CalendarView: View {
    @State private var selectedDate: Date = Date()
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil
    @State private var activeEvent: CalendarEvent? = nil
    @State private var now: Date = Date()

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
                    onEdit: { activeEvent = nil }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeEvent)
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
            .onChange(of: focusPerson) { _, _ in scrollToFirstEvent(proxy) }
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
            Color.clear.frame(width: CalendarMockData.TIME_W)
            ForEach(CalendarMockData.people) { p in
                avatarButton(for: p)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func avatarButton(for p: CalendarPerson) -> some View {
        let focused = focusPerson == p.id
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
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
        case "liam": return ChildProfile.liam.avatarURL
        case "maya": return ChildProfile.maya.avatarURL
        case "emma": return ChildProfile.emma.avatarURL
        default: return nil
        }
    }

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !allDayItems.isEmpty {
                HStack(spacing: 8) {
                    Text("ALL DAY")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    ForEach(allDayItems) { item in
                        let p = CalendarMockData.person(item.col)
                        Text(item.title)
                            .font(.custom("Inter", size: 12).weight(.semibold))
                            .foregroundStyle(p.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(p.bg))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(alignment: .top, spacing: 0) {
                timeGutter
                ZStack(alignment: .topLeading) {
                    ForEach(CalendarMockData.START_H...CalendarMockData.END_H, id: \.self) { h in
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: CGFloat(h) * CalendarMockData.HOUR_H)
                    }

                    ForEach(visibleEvents) { ev in
                        eventPill(ev)
                            .offset(y: CalendarMockData.yFor(ev.start))
                    }

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

    private func eventPill(_ ev: CalendarEvent) -> some View {
        let p = CalendarMockData.person(ev.col)
        let h = CalendarMockData.heightFor(start: ev.start, end: ev.end)
        return Button { activeEvent = ev } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(p.color)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(ev.emoji).font(.system(size: 12))
                        Text(ev.title)
                            .font(.custom("Manrope", size: 12).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                            .lineLimit(1)
                    }
                    Text("\(ev.start) – \(ev.end)")
                        .font(.custom("Inter", size: 9).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: h)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.color.opacity(0.3), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
        Button {} label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.evPrimary))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
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
