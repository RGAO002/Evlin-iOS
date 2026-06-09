import XCTest
@testable import Evlin_iOS

/// Wire-contract tests for the calendar DTOs. The shapes mirror the as-built
/// backend (Evlin-Backend-ov2/app/schemas/calendar.py): GET returns an envelope
/// of `CalendarOccurrenceDTO` (event_id + occurrence_start/end); POST/PUT return
/// a `CalendarEventDTO` (id + start_at/end_at).
final class CalendarEventDTOTests: XCTestCase {

    // MARK: GET — occurrence envelope

    func test_decodesOccurrenceEnvelopeWithParticipants() throws {
        let eventID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let childID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let data = """
        {
          "occurrences": [
            {
              "event_id": "\(eventID.uuidString)",
              "title": "Piano Practice",
              "emoji": "🎹",
              "icon": null,
              "category": "Lesson",
              "location": "Living Room",
              "note": "Work on the new piece.",
              "all_day": false,
              "timezone": "America/New_York",
              "recurrence_type": "weekly",
              "occurrence_start": "2026-06-09T14:00:00Z",
              "occurrence_end": "2026-06-09T15:30:00Z",
              "participants": [
                { "participant_kind": "child", "child_profile_id": "\(childID.uuidString)" }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(CalendarEventsListResponse.self, from: data)
        XCTAssertEqual(envelope.occurrences.count, 1)
        let occ = envelope.occurrences[0]
        XCTAssertEqual(occ.event_id, eventID)
        XCTAssertEqual(occ.title, "Piano Practice")
        XCTAssertEqual(occ.emoji, "🎹")
        XCTAssertEqual(occ.category, "Lesson")
        XCTAssertEqual(occ.all_day, false)
        XCTAssertEqual(occ.recurrence_type, "weekly")
        XCTAssertEqual(occ.occurrence_start, "2026-06-09T14:00:00Z")
        XCTAssertEqual(occ.occurrence_end, "2026-06-09T15:30:00Z")
        XCTAssertEqual(occ.participants.count, 1)
        XCTAssertEqual(occ.participants[0].participant_kind, "child")
        XCTAssertEqual(occ.participants[0].child_profile_id, childID)
    }

    func test_decodesFamilyParticipantWithNullChildId() throws {
        let data = """
        {
          "occurrences": [
            {
              "event_id": "11111111-1111-1111-1111-111111111111",
              "title": "Family Dinner",
              "emoji": "🍴",
              "category": "Family",
              "location": "Dining Room",
              "note": "",
              "all_day": false,
              "timezone": "America/New_York",
              "recurrence_type": "none",
              "occurrence_start": "2026-06-09T22:00:00Z",
              "occurrence_end": "2026-06-09T23:00:00Z",
              "participants": [ { "participant_kind": "family", "child_profile_id": null } ]
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(CalendarEventsListResponse.self, from: data)
        let occ = try XCTUnwrap(envelope.occurrences.first)
        XCTAssertEqual(occ.participants.count, 1)
        XCTAssertNil(occ.participants[0].child_profile_id)
        XCTAssertEqual(occ.participants[0].participant_kind, "family")
    }

    func test_decodesEmptyEnvelope() throws {
        let data = #"{ "occurrences": [] }"#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(CalendarEventsListResponse.self, from: data)
        XCTAssertTrue(envelope.occurrences.isEmpty)
    }

    // MARK: POST/PUT — base event

    func test_decodesBaseEventWithIdAndStartAt() throws {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let familyID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let data = """
        {
          "id": "\(id.uuidString)",
          "family_id": "\(familyID.uuidString)",
          "title": "Soccer",
          "emoji": "⚽",
          "category": "Sport",
          "location": "City Park",
          "note": "Shin guards.",
          "all_day": false,
          "start_at": "2026-06-09T20:00:00Z",
          "end_at": "2026-06-09T21:30:00Z",
          "start_date": null,
          "end_date": null,
          "timezone": "America/New_York",
          "recurrence_type": "daily",
          "recurrence_until": null,
          "participants": [ { "participant_kind": "family", "child_profile_id": null } ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(CalendarEventDTO.self, from: data)
        XCTAssertEqual(dto.id, id)
        XCTAssertEqual(dto.family_id, familyID)
        XCTAssertEqual(dto.start_at, "2026-06-09T20:00:00Z")
        XCTAssertEqual(dto.end_at, "2026-06-09T21:30:00Z")
        XCTAssertEqual(dto.recurrence_type, "daily")
        XCTAssertNil(dto.recurrence_until)
    }

    // MARK: Create body encoding

    func test_createBodyEncodesSnakeCaseContract() throws {
        let childID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let body = CalendarEventCreateBody(
            title: "Soccer",
            emoji: "⚽",
            category: "Sport",
            location: "City Park",
            note: "Shin guards.",
            all_day: false,
            start_at: "2026-06-09T20:00:00Z",
            end_at: "2026-06-09T21:30:00Z",
            timezone: "America/New_York",
            recurrence_type: "daily",
            recurrence_until: nil,
            participants: [ .init(participant_kind: "child", child_profile_id: childID) ]
        )

        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Soccer")
        XCTAssertEqual(json["recurrence_type"] as? String, "daily")
        XCTAssertEqual(json["timezone"] as? String, "America/New_York")
        XCTAssertEqual(json["start_at"] as? String, "2026-06-09T20:00:00Z")
        let parts = try XCTUnwrap(json["participants"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["participant_kind"] as? String, "child")
        XCTAssertEqual(parts[0]["child_profile_id"] as? String, childID.uuidString)
    }

    // MARK: Time conversion helper

    func test_localClockStringConvertsUTCIntoEventTimezone() {
        // 14:00 UTC on 2026-06-09 == 10:00 AM in America/New_York (EDT, -4).
        let label = CalendarWireTime.localClockString(
            isoUTC: "2026-06-09T14:00:00Z", timezoneID: "America/New_York")
        XCTAssertEqual(label, "10:00 AM")
    }

    func test_localClockStringFallsBackToCurrentTZForBadTimezone() {
        let label = CalendarWireTime.localClockString(
            isoUTC: "2026-06-09T14:00:00Z", timezoneID: "Not/AZone")
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: APIClient URL shape (P0 #2 — no double /api/v1)

    func test_calendarEventsWindowURLEncodesISOStartEnd() throws {
        let client = APIClient(baseURL: "https://example.test/api/v1")
        let url = client.calendarEventsWindowURL(
            startISO: "2026-06-09T00:00:00Z", endISO: "2026-06-10T00:00:00Z")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.test")
        XCTAssertEqual(url.path, "/api/v1/calendar/events")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["start"], "2026-06-09T00:00:00Z")
        XCTAssertEqual(items["end"], "2026-06-10T00:00:00Z")
    }

    func test_calendarEventsWindowPathIsRelativeNoBaseURL() {
        let client = APIClient(baseURL: "https://example.test/api/v1")
        let path = client.calendarEventsWindowPath(
            startISO: "2026-06-09T00:00:00Z", endISO: "2026-06-10T00:00:00Z")
        // Must NOT contain the baseURL / a second /api/v1; it is the relative
        // path appended to baseURL by authedRequest.
        XCTAssertTrue(path.hasPrefix("/calendar/events?"))
        XCTAssertFalse(path.contains("api/v1"))
        XCTAssertFalse(path.contains("example.test"))
    }
}
