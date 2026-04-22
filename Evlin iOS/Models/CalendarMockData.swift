import SwiftUI

struct CalendarPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let bg: Color
}

struct CalendarEvent: Identifiable, Hashable {
    let id = UUID()
    let col: String
    let title: String
    let emoji: String
    let start: String
    let end: String
    let category: String
    let location: String
    let note: String
}

struct AllDayItem: Identifiable, Hashable {
    let id = UUID()
    let col: String
    let title: String
}

enum CalendarMockData {
    static let HOUR_H: CGFloat = 56
    static let START_H: Int = 0
    static let END_H: Int = 24
    static let TIME_W: CGFloat = 48

    static let people: [CalendarPerson] = [
        .init(id: "family", name: "Family events",
              color: Color(hex: 0x7C6FF7), bg: Color(hex: 0xEDE9FE)),
        .init(id: "liam", name: "Liam",
              color: .evChildLiam, bg: Color(hex: 0xDBEAFE)),
        .init(id: "maya", name: "Maya",
              color: Color(hex: 0x3DAA5C), bg: Color(hex: 0xDCFCE7)),
        .init(id: "emma", name: "Emma",
              color: Color(hex: 0xF97316), bg: Color(hex: 0xFFEDD5)),
    ]

    // Events keyed by days-offset from today
    static let eventsByOffset: [Int: [CalendarEvent]] = [
        0: [
            CalendarEvent(col: "liam",   title: "Clean Table",     emoji: "🧹",
                          start: "08:00 AM", end: "08:30 AM", category: "Chore",
                          location: "Kitchen", note: "Wipe down the kitchen table and chairs after lunch."),
            CalendarEvent(col: "maya",   title: "Piano Practice",  emoji: "🎹",
                          start: "10:00 AM", end: "11:30 AM", category: "Lesson",
                          location: "Living Room", note: "Work on the new piece from last week. Focus on the right-hand part."),
            CalendarEvent(col: "family", title: "Family Lunch",    emoji: "🍽️",
                          start: "12:00 PM", end: "01:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone together. No devices at the table."),
            CalendarEvent(col: "liam",   title: "Math Practice",   emoji: "📐",
                          start: "01:30 PM", end: "02:30 PM", category: "Study",
                          location: "Study Room", note: "Chapter 7 exercises, pages 112-118."),
            CalendarEvent(col: "emma",   title: "Reading Time",    emoji: "📚",
                          start: "02:00 PM", end: "03:00 PM", category: "Study",
                          location: "Bedroom", note: "Choose one book from the reading list."),
            CalendarEvent(col: "maya",   title: "Art Class",       emoji: "🎨",
                          start: "03:30 PM", end: "05:00 PM", category: "Lesson",
                          location: "Art Studio", note: "Bring the watercolor set."),
            CalendarEvent(col: "liam",   title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Don't forget shin guards."),
            CalendarEvent(col: "family", title: "Family Dinner",   emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
            CalendarEvent(col: "emma",   title: "Story Time",      emoji: "🌙",
                          start: "07:30 PM", end: "08:30 PM", category: "Routine",
                          location: "Bedroom", note: "Two stories max, then lights out."),
        ],
        7: [
            CalendarEvent(col: "liam", title: "Science Lab", emoji: "🔬",
                          start: "10:00 AM", end: "11:30 AM", category: "Study",
                          location: "Study Room", note: "Volcanos experiment."),
            CalendarEvent(col: "maya", title: "Reading", emoji: "📖",
                          start: "09:00 AM", end: "10:00 AM", category: "Study",
                          location: "Living Room", note: "Finish chapter 4."),
            CalendarEvent(col: "family", title: "Library Trip", emoji: "🏛️",
                          start: "01:00 PM", end: "03:00 PM", category: "Family",
                          location: "Central Library", note: "Each kid picks two new books."),
            CalendarEvent(col: "emma", title: "Nap Time", emoji: "😴",
                          start: "02:00 PM", end: "03:30 PM", category: "Routine",
                          location: "Bedroom", note: "Keep the house quiet."),
            CalendarEvent(col: "liam", title: "Soccer Practice", emoji: "⚽",
                          start: "04:00 PM", end: "05:30 PM", category: "Sport",
                          location: "City Park", note: "Arrive 10 min early today."),
            CalendarEvent(col: "family", title: "Family Dinner", emoji: "🍴",
                          start: "06:00 PM", end: "07:00 PM", category: "Family",
                          location: "Dining Room", note: "Everyone helps set the table."),
        ],
    ]

    static let allDayByOffset: [Int: [AllDayItem]] = [
        0: [AllDayItem(col: "liam", title: "Wellness Day 🧘")],
    ]

    // MARK: - Date helpers

    static func daysFromToday(to date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    static func events(for date: Date) -> [CalendarEvent] {
        eventsByOffset[daysFromToday(to: date)] ?? []
    }

    static func allDay(for date: Date) -> [AllDayItem] {
        allDayByOffset[daysFromToday(to: date)] ?? []
    }

    static func shortDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    static func monthName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "LLLL"
        return f.string(from: date)
    }

    static func parseTimeToMinutes(_ s: String) -> Int {
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return 0 }
        let hm = parts[0].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return 0 }
        var h = hm[0]
        let m = hm[1]
        let period = String(parts[1])
        if period == "PM", h != 12 { h += 12 }
        if period == "AM", h == 12 { h = 0 }
        return h * 60 + m
    }

    static func yFor(_ timeStr: String) -> CGFloat {
        let mins = parseTimeToMinutes(timeStr)
        return CGFloat(mins) / 60 * HOUR_H
    }

    static func heightFor(start: String, end: String) -> CGFloat {
        let h = yFor(end) - yFor(start)
        return max(h, 36)
    }

    static func yForNow() -> CGFloat {
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        let m = cal.component(.minute, from: Date())
        return (CGFloat(h) + CGFloat(m) / 60) * HOUR_H
    }

    static func person(_ id: String) -> CalendarPerson {
        people.first(where: { $0.id == id }) ?? people[0]
    }
}
