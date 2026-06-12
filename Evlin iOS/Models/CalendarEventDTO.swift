import Foundation

// Calendar wire DTOs — field names are the backend snake_case JSON keys verbatim
// (authoritative source: Evlin-Backend-ov2/app/schemas/calendar.py).
//
// There are TWO DTO families, because the backend uses two different shapes:
//   • `CalendarOccurrenceDTO` — what `GET /calendar/events` returns. The list
//     endpoint expands recurrence server-side, so each row is ONE occurrence
//     carrying the base `event_id` (NOT `id`) plus `occurrence_start`/`_end`.
//     It does NOT carry start_at/end_at/start_date/end_date/family_id/
//     recurrence_until — those live only on the base event.
//   • `CalendarEventDTO` — the stored base event, returned by POST/PUT. It uses
//     `id` (NOT `event_id`) and carries start_at/end_at OR start_date/end_date.
//
// The GET response is an ENVELOPE: `{ "occurrences": [CalendarOccurrenceDTO] }`.

// MARK: - Participant

struct CalendarEventParticipantDTO: Codable, Sendable, Equatable {
    let participant_kind: String      // "child" | "family"
    let child_profile_id: UUID?       // null when participant_kind == "family"

    init(participant_kind: String, child_profile_id: UUID?) {
        self.participant_kind = participant_kind
        self.child_profile_id = child_profile_id
    }

    enum CodingKeys: String, CodingKey {
        case participant_kind, child_profile_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participant_kind = try c.decodeIfPresent(String.self, forKey: .participant_kind) ?? "family"
        child_profile_id = try c.decodeIfPresent(UUID.self, forKey: .child_profile_id)
    }
}

// MARK: - GET /calendar/events — occurrence + envelope

/// One expanded occurrence (GET window). Carries the base `event_id` +
/// `occurrence_start`/`occurrence_end` so iOS can group a series back to its
/// source event and an edit/delete targets the right base event.
struct CalendarOccurrenceDTO: Codable, Sendable, Equatable, Identifiable {
    let event_id: UUID
    let title: String
    let emoji: String?
    let icon: String?
    let category: String?
    let location: String?
    let note: String?
    let all_day: Bool
    let timezone: String
    let recurrence_type: String       // none|daily|weekdays|weekly|monthly
    let occurrence_start: String      // ISO8601 UTC instant of THIS occurrence
    let occurrence_end: String
    let participants: [CalendarEventParticipantDTO]
    let reminder_minutes_before: Int?   // nil = none; 30 = "30 minutes before"

    /// SwiftUI identity: one base event can fan out to many occurrences in a
    /// window, so combine the event id with the occurrence start to stay unique.
    var id: String { "\(event_id.uuidString)|\(occurrence_start)" }

    // Tolerate older/partial payloads: optional keys decode to nil/[]/defaults
    // rather than throwing.
    enum CodingKeys: String, CodingKey {
        case event_id, title, emoji, icon, category, location, note
        case all_day, timezone, recurrence_type
        case occurrence_start, occurrence_end, participants
        case reminder_minutes_before
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event_id = try c.decode(UUID.self, forKey: .event_id)
        title = try c.decode(String.self, forKey: .title)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        all_day = try c.decodeIfPresent(Bool.self, forKey: .all_day) ?? false
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
            ?? TimeZone.current.identifier
        recurrence_type = try c.decodeIfPresent(String.self, forKey: .recurrence_type) ?? "none"
        occurrence_start = try c.decode(String.self, forKey: .occurrence_start)
        occurrence_end = try c.decode(String.self, forKey: .occurrence_end)
        participants = try c.decodeIfPresent([CalendarEventParticipantDTO].self, forKey: .participants) ?? []
        reminder_minutes_before = try c.decodeIfPresent(Int.self, forKey: .reminder_minutes_before)
    }
}

/// Envelope returned by `GET /calendar/events` — `{ "occurrences": [...] }`.
struct CalendarEventsListResponse: Codable, Sendable {
    let occurrences: [CalendarOccurrenceDTO]

    enum CodingKeys: String, CodingKey { case occurrences }

    init(occurrences: [CalendarOccurrenceDTO]) { self.occurrences = occurrences }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        occurrences = try c.decodeIfPresent([CalendarOccurrenceDTO].self, forKey: .occurrences) ?? []
    }
}

// MARK: - POST/PUT response — the stored base event

/// The stored base event, returned by `POST`/`PUT /calendar/events`. Uses `id`
/// (NOT `event_id`) and carries the full time fields + family/recurrence_until.
struct CalendarEventDTO: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let family_id: UUID
    let title: String
    let emoji: String?
    let icon: String?
    let category: String?
    let location: String?
    let note: String?
    let all_day: Bool
    let start_at: String?             // ISO8601 UTC; nil when all_day
    let end_at: String?
    let start_date: String?           // YYYY-MM-DD when all_day
    let end_date: String?
    let timezone: String
    let recurrence_type: String       // none|daily|weekdays|weekly|monthly
    let recurrence_until: String?
    let participants: [CalendarEventParticipantDTO]

    enum CodingKeys: String, CodingKey {
        case id, family_id, title, emoji, icon, category, location, note
        case all_day, start_at, end_at, start_date, end_date, timezone
        case recurrence_type, recurrence_until, participants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        family_id = try c.decode(UUID.self, forKey: .family_id)
        title = try c.decode(String.self, forKey: .title)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        all_day = try c.decodeIfPresent(Bool.self, forKey: .all_day) ?? false
        start_at = try c.decodeIfPresent(String.self, forKey: .start_at)
        end_at = try c.decodeIfPresent(String.self, forKey: .end_at)
        start_date = try c.decodeIfPresent(String.self, forKey: .start_date)
        end_date = try c.decodeIfPresent(String.self, forKey: .end_date)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
            ?? TimeZone.current.identifier
        recurrence_type = try c.decodeIfPresent(String.self, forKey: .recurrence_type) ?? "none"
        recurrence_until = try c.decodeIfPresent(String.self, forKey: .recurrence_until)
        participants = try c.decodeIfPresent([CalendarEventParticipantDTO].self, forKey: .participants) ?? []
    }
}

// MARK: - Wire bodies (CreateCalendarEventBody / UpdateCalendarEventBody)

/// Body for `POST /calendar/events`. Timed events require start_at+end_at.
/// (P0 creates timed events only; all-day creation is deferred to P1.)
struct CalendarEventCreateBody: Codable, Sendable {
    var title: String
    var emoji: String?
    var category: String?
    var location: String?
    var note: String?
    var all_day: Bool
    var start_at: String?
    var end_at: String?
    var timezone: String
    var recurrence_type: String
    var recurrence_until: String?
    var reminder_minutes_before: Int? = nil
    var participants: [CalendarEventParticipantDTO]
}

/// Body for `PUT /calendar/events/{id}`. All fields optional; participants when
/// non-nil REPLACE the full set (omit to leave untouched).
struct CalendarEventUpdateBody: Codable, Sendable {
    var title: String?
    var emoji: String?
    var category: String?
    var location: String?
    var note: String?
    var all_day: Bool?
    var start_at: String?
    var end_at: String?
    var timezone: String?
    var recurrence_type: String?
    var recurrence_until: String?
    var reminder_minutes_before: Int? = nil
    var participants: [CalendarEventParticipantDTO]?

    enum CodingKeys: String, CodingKey {
        case title, emoji, category, location, note, all_day
        case start_at, end_at, timezone, recurrence_type, recurrence_until
        case reminder_minutes_before, participants
    }

    /// Every field but `reminder_minutes_before` uses omit-to-leave-untouched
    /// (encodeIfPresent). The reminder is ALWAYS sent — including an explicit
    /// `null` — so that toggling it OFF actually clears it on the backend
    /// (the synthesized encoder would otherwise drop a nil and the reminder
    /// would silently persist). Pairs with the backend's `model_fields_set` gate.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(all_day, forKey: .all_day)
        try c.encodeIfPresent(start_at, forKey: .start_at)
        try c.encodeIfPresent(end_at, forKey: .end_at)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        try c.encodeIfPresent(recurrence_type, forKey: .recurrence_type)
        try c.encodeIfPresent(recurrence_until, forKey: .recurrence_until)
        try c.encode(reminder_minutes_before, forKey: .reminder_minutes_before)
        try c.encodeIfPresent(participants, forKey: .participants)
    }
}

// MARK: - Time conversion at the wire boundary

enum CalendarWireTime {
    /// Strict UTC ISO8601 formatter (the backend emits `...Z`). Used for both
    /// emit (write) and a fast-path parse (read).
    static let isoUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse a UTC ISO8601 instant into an absolute `Date`. Tolerates fractional
    /// seconds. Returns nil if unparseable.
    static func parseInstant(_ isoUTC: String) -> Date? {
        if let d = isoUTC.isEmpty ? nil : Self.isoUTC.date(from: isoUTC) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        frac.timeZone = TimeZone(identifier: "UTC")
        return frac.date(from: isoUTC)
    }

    /// Render a UTC ISO instant as a wall-clock `"hh:mm a"` label IN the event's
    /// IANA timezone — the exact format `CalendarMockData.parseTimeToMinutes`
    /// already understands. Falls back to the device timezone for an unknown id.
    static func localClockString(isoUTC: String, timezoneID: String) -> String {
        guard let date = parseInstant(isoUTC) else { return "12:00 AM" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a"
        f.timeZone = TimeZone(identifier: timezoneID) ?? .current
        return f.string(from: date)
    }
}
