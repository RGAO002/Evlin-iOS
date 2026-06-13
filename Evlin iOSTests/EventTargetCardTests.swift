import XCTest
@testable import Evlin_iOS

final class EventTargetCardTests: XCTestCase {
    // MARK: - Task 1: AgentClient request builders

    func testAgentClientBuildsEventExecRequest() throws {
        let c = AgentClient(baseURL: "https://example.com")
        let req = try c.makeEventExecRequest(token: "tok123")
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/parent/agent/event-exec")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["token"] as? String, "tok123")
    }

    func testAgentClientBuildsResolveTargetRequest() throws {
        let c = AgentClient(baseURL: "https://example.com")
        let req = try c.makeResolveTargetRequest(continuationToken: "ct", selectedIds: ["a", "b"])
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/parent/agent/resolve-target")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["continuation_token"] as? String, "ct")
        XCTAssertEqual(body?["selected_ids"] as? [String], ["a", "b"])
    }

    // MARK: - Task 2: EventTargetDetail extraction

    func testDetailExtractsTokenAndOptions() throws {
        let json = """
        {"type":"danger_confirm","kind":"target.child_select","source":"event",
         "title":"Which child?","detail":{"continuation_token":"ct1",
           "options":[{"label":"Liam","id":"id-1"},{"label":"Emma","id":"id-2"}]}}
        """.data(using: .utf8)!
        let card = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        let d = EventTargetDetail(card.detail)
        XCTAssertEqual(d.string("continuation_token"), "ct1")
        let opts = d.options("options")
        XCTAssertEqual(opts.map(\.id), ["id-1", "id-2"])
        XCTAssertEqual(opts.map(\.label), ["Liam", "Emma"])
    }

    func testDetailExtractsGroups() throws {
        let json = """
        {"type":"danger_confirm","kind":"target.device_select","source":"event",
         "title":"Which device?","detail":{"continuation_token":"ct2",
           "groups":[{"child_name":"Liam","options":[{"label":"iPhone","id":"d-1"}]}]}}
        """.data(using: .utf8)!
        let card = try JSONDecoder().decode(PlanArchCardPayload.self, from: json)
        let d = EventTargetDetail(card.detail)
        let groups = d.groups("groups")
        XCTAssertEqual(groups.first?.childName, "Liam")
        XCTAssertEqual(groups.first?.options.first?.id, "d-1")
    }

    // MARK: - Task 3: TargetSelectionModel stable ids

    func testTargetSelectionReturnsStableIds() {
        // The selection model returns the STABLE ids of checked rows (not labels),
        // so duplicate-name children / same-label devices remain resolvable (§5.1).
        var model = TargetSelectionModel(options: [
            TargetOption(id: "id-1", label: "Liam"),
            TargetOption(id: "id-2", label: "Liam")])   // same label, different ids
        model.toggle("id-2")
        XCTAssertEqual(model.selectedIds, ["id-2"])
        model.toggle("id-1")
        XCTAssertEqual(Set(model.selectedIds), Set(["id-1", "id-2"]))
    }

    // MARK: - Task 4: EventTargetRoute kind routing

    func testKindRoutingDecision() {
        XCTAssertEqual(EventTargetRoute(kind: "event.create_confirm"), .confirm)
        XCTAssertEqual(EventTargetRoute(kind: "event.bundle_confirm"), .confirm)
        XCTAssertEqual(EventTargetRoute(kind: "event.result"), .result)
        XCTAssertEqual(EventTargetRoute(kind: "event.disambiguation"), .disambiguation)
        XCTAssertEqual(EventTargetRoute(kind: "target.child_select"), .targetSelect)
        XCTAssertEqual(EventTargetRoute(kind: "target.device_select"), .targetSelect)
        XCTAssertEqual(EventTargetRoute(kind: "event.reflection_review_pending"), .reflection)
        XCTAssertNil(EventTargetRoute(kind: "phone.proposal_confirm"))
    }

    // MARK: - Task P6: event.scope route + request builder

    func testEventScopeRouteAndRequest() throws {
        XCTAssertEqual(EventTargetRoute(kind: "event.scope"), .scope)
        let c = AgentClient(baseURL: "https://example.com")
        let req = try c.makeEventScopeRequest(continuationToken: "ct", scope: "series")
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/parent/agent/event-scope")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["continuation_token"] as? String, "ct")
        XCTAssertEqual(body?["scope"] as? String, "series")
    }
}
