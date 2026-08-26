import XCTest
@testable import Evlin_iOS

/// The 2026-08-21 dead-button family: five polished templates (A1, A3, B1,
/// E1, F1) rendered primary/secondary buttons wired to `h.onPrimary ?? {}`
/// while the plan-arch handler factory left both nil — live-looking buttons
/// that did nothing. The bridge forwards the card's OWN backend-authored
/// options positionally; these tests pin that mapping and its exclusions.
final class PlanArchTemplateActionBridgeTests: XCTestCase {

    private func payload(
        kind: String,
        options: [[String: Any]],
        detail: [String: Any] = [:]
    ) -> PlanArchCardPayload {
        let body: [String: Any] = [
            "type": "duration_picker",
            "title": "test",
            "plan_token": "x",
            "step_index": 0,
            "kind": kind,
            "source": "plan",
            "detail": detail,
            "options": options,
            "danger": "low",
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(PlanArchCardPayload.self, from: data)
    }

    func testDangerConfirmWiresPrimaryAndSecondaryFromNonCancelOptions() throws {
        let card = payload(
            kind: "phone.danger_confirm",
            options: [
                ["label": "Block TikTok", "patch": ["intent_confirmed": true], "cancels_plan": false],
                ["label": "Shield instead", "patch": ["use_shield": true], "cancels_plan": false],
                ["label": "Cancel", "patch": [:], "cancels_plan": true],
            ],
            detail: ["action_summary": "Block TikTok"]
        )
        let wiring = try XCTUnwrap(
            PlanArchTemplateActionBridge.wiring(for: card, childName: "Liam")
        )
        XCTAssertEqual(wiring.primary.label, "Block TikTok")
        XCTAssertFalse(wiring.primary.cancelsPlan)
        XCTAssertEqual(wiring.secondary?.label, "Shield instead")
    }

    func testSingleOptionCardWiresPrimaryOnly() throws {
        let card = payload(
            kind: "phone.danger_confirm",
            options: [
                ["label": "Unblock all", "patch": ["intent_confirmed": true], "cancels_plan": false],
                ["label": "Cancel", "patch": [:], "cancels_plan": true],
            ],
            detail: ["action_summary": "Unblock all"]
        )
        let wiring = try XCTUnwrap(
            PlanArchTemplateActionBridge.wiring(for: card, childName: "Liam")
        )
        XCTAssertEqual(wiring.primary.label, "Unblock all")
        XCTAssertNil(wiring.secondary)
    }

    func testCancelOnlyCardGetsNoWiring() {
        let card = payload(
            kind: "phone.danger_confirm",
            options: [["label": "Cancel", "patch": [:], "cancels_plan": true]],
            detail: ["action_summary": "Block"]
        )
        XCTAssertNil(PlanArchTemplateActionBridge.wiring(for: card, childName: "Liam"))
    }

    func testDurationDrivenTemplateIsExcluded() {
        // D1 runs on onDurationPicked; positional primary wiring would fight
        // the dedicated handler.
        let card = payload(
            kind: "phone.missing_duration",
            options: [
                ["label": "15 minutes", "patch": ["duration": ["kind": "minutes", "value": 15]], "cancels_plan": false],
            ],
            detail: ["target_name": "YouTube"]
        )
        XCTAssertNil(PlanArchTemplateActionBridge.wiring(for: card, childName: "Liam"))
    }

    func testUnknownKindGetsNoWiring() {
        let card = payload(
            kind: "future.kind",
            options: [["label": "Go", "patch": [:], "cancels_plan": false]]
        )
        XCTAssertNil(PlanArchTemplateActionBridge.wiring(for: card, childName: "Liam"))
    }

    /// The factory itself must produce live handlers for a template-driven
    /// card — this is the exact assertion that was false on 2026-08-21.
    @MainActor
    func testHandlerFactoryProducesLivePrimaryForDangerConfirm() {
        let vm = ChatViewModel()
        let card = payload(
            kind: "phone.danger_confirm",
            options: [
                ["label": "Block TikTok", "patch": ["intent_confirmed": true], "cancels_plan": false],
                ["label": "Cancel", "patch": [:], "cancels_plan": true],
            ],
            detail: ["action_summary": "Block TikTok"]
        )
        let handlers = vm.makePlanArchHandlers(for: card)
        XCTAssertNotNil(handlers.onPrimary, "the confirm button must do something")
    }

    @MainActor
    func testHandlerFactoryStillLeavesDurationCardsToTheirDedicatedHandler() {
        let vm = ChatViewModel()
        let card = payload(
            kind: "phone.missing_duration",
            options: [],
            detail: ["target_name": "YouTube"]
        )
        let handlers = vm.makePlanArchHandlers(for: card)
        XCTAssertNil(handlers.onPrimary)
        XCTAssertNotNil(handlers.onDurationPicked)
    }
}
