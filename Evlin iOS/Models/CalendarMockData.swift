import SwiftUI

struct CalendarPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let bg: Color
}

struct CalendarEvent: Identifiable, Hashable {
    let id = UUID()
    let col: String          // "family" / "liam" / "maya" / "emma"
    let title: String
    let emoji: String
    let start: String        // "08:00 AM"
    let end: String          // "08:30 AM"
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
        .init(id: "family", name: "Family",
              color: Color(hex: 0x7C6FF7), bg: Color(hex: 0xEDE9FE)),
        .init(id: "liam", name: "Liam",
              color: .evChildLiam, bg: Color(hex: 0xDBEAFE)),
        .init(id: "maya", name: "Maya",
              color: Color(hex: 0x3DAA5C), bg: Color(hex: 0xDCFCE7)),
        .init(id: "emma", name: "Emma",
              color: Color(hex: 0xF97316), bg: Color(hex: 0xFFEDD5)),
    ]

    static let dayNames: [Int: String] = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat",
        8: "Mon", 9: "Tue", 10: "Wed", 11: "Thu", 12: "Thu", 13: "Fri", 14: "Sat",
        15: "Sun", 16: "Mon", 17: "Tue", 18: "Wed", 19: "Thu", 20: "Fri", 21: "Sat",
        22: "Sun", 23: "Mon", 24: "Tue", 25: "Wed", 26: "Thu", 27: "Fri", 28: "Sat",
        29: "Sun", 30: "Mon",
    ]

    static let events: [Int: [CalendarEvent]] = [
        12: [
            CalendarEvent(col: "liam",   title: "Clean Table",     emoji: "🧹",
                          start: "08:00 AM", end: "08:30 AM", category: "Chore",
                          location: "Kitchen", note: "Wipe down the kitchen table and chairs after lunch."),
            CalendarEvent(col: "maya",   title: "Piano Practice",  emoji: "🎹",
                          start: "10:00 AM", end: "11:30 AM", category: "Lesson",
                          location: "Living Room", note: "Work on the new piece from last week."),
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
        19: [
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

    static let allDay: [Int: [AllDayItem]] = [
        12: [AllDayItem(col: "liam", title: "Wellness Day 🧘")],
    ]

    // Parse "08:00 AM" into total minutes from midnight
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

    static func person(_ id: String) -> CalendarPerson {
        people.first(where: { $0.id == id }) ?? people[0]
    }
}
