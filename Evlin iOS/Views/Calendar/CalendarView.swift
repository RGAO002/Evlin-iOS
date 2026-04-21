import SwiftUI

struct CalendarView: View {
    @State private var selectedDay: Int = 12
    @State private var showMonthPicker = false
    @State private var focusPerson: String? = nil
    @State private var activeEvent: CalendarEvent? = nil

    private let totalHeight: CGFloat = CGFloat(CalendarMockData.END_H) * CalendarMockData.HOUR_H

    private var events: [CalendarEvent] {
        CalendarMockData.events[selectedDay] ?? []
    }
    private var visibleEvents: [CalendarEvent] {
        guard let focusPerson else { return events }
        return events.filter { $0.col == focusPerson }
    }
    private var allDayItems: [AllDayItem] {
        CalendarMockData.allDay[selectedDay] ?? []
    }
    private var dayLabel: String {
        let name = CalendarMockData.dayNames[selectedDay] ?? "—"
        return "\(name), Sep \(selectedDay)"
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Schedule", kicker: "September") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: focusPerson == nil ? "person.2" : "person.fill") {
                        cycleFocus()
                    }
                }
            }

            dayNav

            ScrollViewReader { proxy in
                ScrollView {
                    timelineBody
                        .id("timeline")
                }
                .onAppear {
                    scrollToFirstEvent(proxy)
                }
                .onChange(of: selectedDay) { _, _ in
                    scrollToFirstEvent(proxy)
                }
            }
        }
        .background(Color(hex: 0xF0F4F8))
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(selectedDay: $selectedDay, onClose: { showMonthPicker = false })
        }
        .sheet(item: $activeEvent) { event in
            EventDetailSheet(
                event: event,
                person: CalendarMockData.person(event.col),
                dayLabel: dayLabel,
                onClose: { activeEvent = nil }
            )
        }
    }

    private var dayNav: some View {
        HStack {
            navButton(systemName: "chevron.left") {
                selectedDay = max(1, selectedDay - 1)
            }
            Spacer()
            Button {
                showMonthPicker = true
            } label: {
                VStack(spacing: 1) {
                    Text(dayLabel)
                        .font(.custom("Manrope", size: 17).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Text("TAP TO CHANGE DATE")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            navButton(systemName: "chevron.right") {
                selectedDay = min(30, selectedDay + 1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(Color(hex: 0xF0F4F8).opacity(0.97))
        .overlay(
            Rectangle().fill(Color.evOutlineVariant).frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.evPrimary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                )
                .evShadow(.premium)
        }
        .buttonStyle(.plain)
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
                .padding(.top, 12)
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
                            .id("ev_\(ev.id)")
                    }
                }
                .frame(height: totalHeight, alignment: .top)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .padding(.bottom, 120)
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
        return Button {
            activeEvent = ev
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(p.color).frame(width: 4).cornerRadius(2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ev.emoji).font(.system(size: 14))
                        Text(ev.title)
                            .font(.custom("Manrope", size: 13).weight(.heavy))
                            .foregroundStyle(Color.evPrimary)
                            .lineLimit(1)
                    }
                    Text(ev.start)
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: h, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func scrollToFirstEvent(_ proxy: ScrollViewProxy) {
        guard let first = visibleEvents.map({ CalendarMockData.yFor($0.start) }).min() else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("timeline", anchor: UnitPoint(x: 0, y: max(0, first - 80) / totalHeight))
        }
    }

    private func cycleFocus() {
        let order: [String?] = [nil, "liam", "maya", "emma", "family"]
        let idx = (order.firstIndex(of: focusPerson) ?? 0)
        focusPerson = order[(idx + 1) % order.count]
    }
}
