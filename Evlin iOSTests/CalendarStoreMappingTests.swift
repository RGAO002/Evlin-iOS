import XCTest
import SwiftUI
@testable import Evlin_iOS

/// Pure-mapper tests for `CalendarStore` / `CalendarTimeWire`. These exercise the
/// DTO→view-model mapping without a network: occurrences map to the right
/// columns + local-clock times, all-day occurrences split into the all-day lane,
/// and the save-boundary converts wall-clock back to UTC ISO.
final class CalendarStoreMappingTests: XCTestCase {

    func test_peopleStartsWithFamilyPseudoPersonThenChildren() {
        // Use the stable production fixtures (ids "liam"/"maya") so the test
        // does not couple to ChildProfile's memberwise init.
        let kids = [ChildProfile.previewLiam, ChildProfile.previewMaya]
        let people = CalendarStore.people(from: kids)
        XCTAssertEqual(people.first?.id, "family")
        XCTAssertEqual(people.first?.name, "Family events")
        XCTAssertEqual(people.map(\.id), ["family", "liam", "maya"])
        XCTAssertEqual(people.map(\.name), ["Family events", "Liam", "Maya"])
    }

    func test_childParticipantMapsToChildColumnWithLocalClockTimes() {
        let childID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let occ = makeOccurrence(
            startUTC: "2026-06-09T14:00:00Z", endUTC: "2026-06-09T15:30:00Z",
            tz: "America/New_York", recurrence: "weekly", allDay: false,
            participants: [.init(participant_kind: "child", child_profile_id: childID)])

        let events = CalendarStore.calendarEvents(from: [occ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].col, childID.uuidString.lowercased())
        XCTAssertEqual(events[0].start, "10:00 AM")   // 14:00Z EDT
        XCTAssertEqual(events[0].end, "11:30 AM")
        XCTAssertEqual(events[0].recurrence, "weekly")
        XCTAssertEqual(events[0].title, "Piano Practice")
        XCTAssertEqual(events[0].backendID, occ.event_id)
    }

    func test_familyParticipantMapsToFamilyColumn() {
        let occ = makeOccurrence(
            startUTC: "2026-06-09T22:00:00Z", endUTC: "2026-06-09T23:00:00Z",
            tz: "America/New_York", recurrence: "none", allDay: false,
            participants: [.init(participant_kind: "family", child_profile_id: nil)])
        let events = CalendarStore.calendarEvents(from: [occ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].col, "family")
    }

    func test_multiChildEventFansOutOneRowPerChildSharingBackendID() {
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let occ = makeOccurrence(
            startUTC: "2026-06-09T14:00:00Z", endUTC: "2026-06-09T15:00:00Z",
            tz: "America/New_York", recurrence: "none", allDay: false,
            participants: [
                .init(participant_kind: "child", child_profile_id: a),
                .init(participant_kind: "child", child_profile_id: b),
            ])
        let events = CalendarStore.calendarEvents(from: [occ])
        XCTAssertEqual(Set(events.map(\.col)),
                       Set([a.uuidString.lowercased(), b.uuidString.lowercased()]))
        XCTAssertEqual(Set(events.map(\.backendID)), [occ.event_id])
    }

    func test_allDayOccurrenceGoesToAllDayLaneNotTimeline() {
        let occ = makeOccurrence(
            startUTC: "2026-06-09T00:00:00Z", endUTC: "2026-06-10T00:00:00Z",
            tz: "America/New_York", recurrence: "none", allDay: true,
            participants: [.init(participant_kind: "family", child_profile_id: nil)])
        // The all-day occurrence must NOT appear in the timeline...
        let timeline = CalendarStore.calendarEvents(from: [occ])
        XCTAssertTrue(timeline.isEmpty)
        // ...but DOES appear in the all-day lane.
        let allDay = CalendarStore.allDayItems(from: [occ])
        XCTAssertEqual(allDay.count, 1)
        XCTAssertEqual(allDay[0].col, "family")
        XCTAssertEqual(allDay[0].title, "Piano Practice")
    }

    // MARK: Save boundary

    func test_wallClockOnDayToUTCISO_roundTripsThroughTimezone() {
        // 10:00 AM America/New_York on 2026-06-09 (EDT) == 14:00:00Z.
        let day = makeDay(year: 2026, month: 6, day: 9, tz: "America/New_York")
        let iso = CalendarTimeWire.utcISO(
            wallClock: "10:00 AM", onDay: day, timezoneID: "America/New_York")
        XCTAssertEqual(iso, "2026-06-09T14:00:00Z")
    }

    func test_participantsFromColumnsMapFamilyAndChildren() {
        let childA = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        let pFamily = CalendarTimeWire.participants(fromColumns: ["family"])
        XCTAssertEqual(pFamily, [.init(participant_kind: "family", child_profile_id: nil)])

        let pChild = CalendarTimeWire.participants(fromColumns: [childA])
        XCTAssertEqual(pChild.count, 1)
        XCTAssertEqual(pChild[0].participant_kind, "child")
        XCTAssertEqual(pChild[0].child_profile_id, UUID(uuidString: childA))
    }

    // MARK: helpers

    private func makeOccurrence(
        startUTC: String, endUTC: String, tz: String, recurrence: String,
        allDay: Bool, participants: [CalendarEventParticipantDTO]
    ) -> CalendarOccurrenceDTO {
        let json = """
        {
          "event_id": "11111111-2222-3333-4444-555555555555",
          "title": "Piano Practice", "emoji": "🎹", "category": "Lesson",
          "location": "Living Room", "note": "n", "all_day": \(allDay),
          "timezone": "\(tz)", "recurrence_type": "\(recurrence)",
          "occurrence_start": "\(startUTC)", "occurrence_end": "\(endUTC)",
          "participants": \(encodeParts(participants))
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(CalendarOccurrenceDTO.self, from: json)
    }

    private func encodeParts(_ p: [CalendarEventParticipantDTO]) -> String {
        let data = try! JSONEncoder().encode(p)
        return String(data: data, encoding: .utf8)!
    }

    private func makeDay(year: Int, month: Int, day: Int, tz: String) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 12  // midday, tz-safe anchor for the calendar day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: comps)!
    }
}
