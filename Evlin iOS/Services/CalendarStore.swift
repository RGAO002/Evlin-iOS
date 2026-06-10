import Foundation
import SwiftUI
import Combine

/// Owns the calendar event window for the parent Calendar tab. Replaces
/// `CalendarMockData.events(for:)` + `runtimeEventsByOffset`. Fetches a per-day
/// window from `GET /calendar/events` (recurrence expanded server-side into
/// occurrences), maps the occurrence DTOs into the existing `CalendarEvent` /
/// `AllDayItem` value types (so the visual layout helpers are untouched), and
/// re-fetches after every create/update/delete so the grid reflects the server.
@MainActor
final class CalendarStore: ObservableObject {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var allDayItems: [AllDayItem] = []
    /// User-visible error from the last mutation (create/update/delete), shown
    /// then cleared by the view.
    @Published var lastError: String?

    /// `var` (not `let`) because the store is created at `@StateObject` init time
    /// with a placeholder client — SwiftUI can't read the environment in init —
    /// and `rebind(api:)` swaps in the shell's real client on first `.onAppear`
    /// before any request fires.
    private var api: APIClient
    init(api: APIClient) { self.api = api }

    /// Swap in the shell's shared APIClient (the one carrying the live baseURL +
    /// auth). Safe to call repeatedly.
    func rebind(api: APIClient) { self.api = api }

    // MARK: - Window fetch

    /// Load all occurrences overlapping the local day `date` (00:00..24:00 device
    /// time, sent as UTC ISO). Keeps the last list on failure if non-empty.
    func load(for date: Date, calendar: Calendar = .current) async {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let startISO = CalendarWireTime.isoUTC.string(from: dayStart)
        let endISO = CalendarWireTime.isoUTC.string(from: dayEnd)
        if events.isEmpty && allDayItems.isEmpty { state = .loading }
        do {
            let occ = try await api.fetchCalendarEvents(startISO: startISO, endISO: endISO)
            self.events = Self.calendarEvents(from: occ)
            self.allDayItems = Self.allDayItems(from: occ)
            state = .loaded
        } catch {
            if events.isEmpty && allDayItems.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Mutations (then refetch the same window)

    func create(_ body: CalendarEventCreateBody, refetchFor date: Date) async {
        lastError = nil
        do {
            _ = try await api.createCalendarEvent(body)
            await load(for: date)
        } catch {
            lastError = "Couldn't create event. \(error.localizedDescription)"
        }
    }

    func update(id: UUID, _ body: CalendarEventUpdateBody, refetchFor date: Date) async {
        lastError = nil
        do {
            _ = try await api.updateCalendarEvent(id: id, body)
            await load(for: date)
        } catch {
            lastError = "Couldn't save changes. \(error.localizedDescription)"
        }
    }

    func delete(id: UUID, refetchFor date: Date) async {
        lastError = nil
        do {
            try await api.deleteCalendarEvent(id: id)
            await load(for: date)
        } catch {
            lastError = "Couldn't delete event. \(error.localizedDescription)"
        }
    }

    // MARK: - Pure mappers (unit-tested, no network)

    /// People columns: a synthetic "family" pseudo-person first, then the real
    /// FamilyStore children (column id == backend child id). Replaces the
    /// hardcoded liam/maya/emma in `CalendarMockData.people`.
    nonisolated static func people(from children: [ChildProfile]) -> [CalendarPerson] {
        let family = CalendarPerson(
            id: "family", name: "Family events",
            color: Color(hex: 0x7C6FF7), bg: Color(hex: 0xEDE9FE))
        let kids = children.map { child in
            CalendarPerson(id: child.id, name: child.name,
                           color: child.accentColor,
                           bg: child.accentColor.opacity(0.14))
        }
        return [family] + kids
    }

    /// Map backend TIMED occurrences to draw-ready `CalendarEvent`s. A
    /// multi-participant occurrence fans out one row per participant column
    /// (sharing `backendID == event_id`). Times come from `occurrence_start`/
    /// `occurrence_end` converted from UTC to the event's IANA timezone as
    /// `"hh:mm a"` so `CalendarMockData.yFor/heightFor` works unchanged. All-day
    /// occurrences are handled by `allDayItems(from:)` and skipped here.
    nonisolated static func calendarEvents(from occurrences: [CalendarOccurrenceDTO]) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for occ in occurrences where !occ.all_day {
            let startStr = CalendarWireTime.localClockString(
                isoUTC: occ.occurrence_start, timezoneID: occ.timezone)
            let endStr = CalendarWireTime.localClockString(
                isoUTC: occ.occurrence_end, timezoneID: occ.timezone)
            let cols = columns(for: occ.participants)
            for col in cols {
                var ev = CalendarEvent(
                    col: col,
                    title: occ.title,
                    emoji: occ.emoji ?? "📌",
                    start: startStr,
                    end: endStr,
                    category: occ.category ?? "Activity",
                    location: occ.location ?? "",
                    note: occ.note ?? "",
                    recurrence: occ.recurrence_type
                )
                ev.backendID = occ.event_id
                // Every fanned-out row carries the FULL participant column set
                // + the event's own timezone so the save boundary can round-trip
                // them (see CalendarEvent doc comments).
                ev.participantCols = cols
                ev.timezone = occ.timezone
                out.append(ev)
            }
        }
        return out
    }

    /// Map backend ALL-DAY occurrences to the all-day lane pills. Fans out one
    /// pill per participant column (same column convention as timed events).
    nonisolated static func allDayItems(from occurrences: [CalendarOccurrenceDTO]) -> [AllDayItem] {
        var out: [AllDayItem] = []
        for occ in occurrences where occ.all_day {
            for col in columns(for: occ.participants) {
                out.append(AllDayItem(col: col, title: occ.title))
            }
        }
        return out
    }

    /// Column ids for an occurrence's participants. A "family" kind → the
    /// "family" column; a child kind → the child profile id (lowercased uuid
    /// string to match the people-column ids). De-duplicated, order-preserving.
    /// Empty/unknown participants fall back to the family column so the row is
    /// never silently dropped.
    nonisolated private static func columns(for participants: [CalendarEventParticipantDTO]) -> [String] {
        if participants.contains(where: { $0.participant_kind == "family" }) {
            return ["family"]
        }
        var seen = Set<String>()
        var cols: [String] = []
        for p in participants where p.participant_kind == "child" {
            guard let cid = p.child_profile_id?.uuidString.lowercased() else { continue }
            if seen.insert(cid).inserted { cols.append(cid) }
        }
        return cols.isEmpty ? ["family"] : cols
    }
}

/// Pure helpers for the save boundary: convert an edited `"hh:mm a"` wall-clock
/// (interpreted on the viewed calendar day, in the event's timezone) back to a
/// UTC ISO instant the backend stores, and build the participants payload from
/// the chosen column ids. Inverse of `CalendarWireTime.localClockString`.
enum CalendarTimeWire {
    static func utcISO(wallClock: String, onDay day: Date, timezoneID: String) -> String? {
        let tz = TimeZone(identifier: timezoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "hh:mm a"
        parser.timeZone = tz
        guard let parsed = parser.date(from: wallClock.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let hm = cal.dateComponents([.hour, .minute], from: parsed)
        let dayComps = cal.dateComponents([.year, .month, .day], from: day)
        var combined = DateComponents()
        combined.year = dayComps.year; combined.month = dayComps.month; combined.day = dayComps.day
        combined.hour = hm.hour; combined.minute = hm.minute
        guard let instant = cal.date(from: combined) else { return nil }
        return CalendarWireTime.isoUTC.string(from: instant)
    }

    /// Build the participants payload from the chosen column ids. "family" →
    /// a single family participant; any other id is treated as a child profile
    /// UUID. Mirrors the backend's `ParticipantInput` invariants.
    static func participants(fromColumns columns: [String]) -> [CalendarEventParticipantDTO] {
        if columns.contains("family") {
            return [.init(participant_kind: "family", child_profile_id: nil)]
        }
        return columns.compactMap { col in
            guard let uuid = UUID(uuidString: col) else { return nil }
            return CalendarEventParticipantDTO(participant_kind: "child", child_profile_id: uuid)
        }
    }
}
