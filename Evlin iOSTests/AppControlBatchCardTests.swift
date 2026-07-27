import XCTest
@testable import Evlin_iOS

/// The client half of the multi-device contract.
///
/// Both sides of a seam can pass their own tests while the seam itself is
/// broken — this project shipped `used_today_minutes` for a month that iOS
/// never read. So these assert the exact strings and shapes the backend emits,
/// not merely that the client is self-consistent.
final class AppControlBatchCardTests: XCTestCase {

    // MARK: - Routing

    /// The generic `target.` prefix is a catch-all that would swallow every
    /// batch card into the device picker. Exact matches must win.
    func testBatchKindsRouteToTheirOwnCases() {
        XCTAssertEqual(EventTargetRoute(kind: "target.app_control_batch_advice"), .batchAdvice)
        XCTAssertEqual(EventTargetRoute(kind: "target.app_control_batch_duration"), .batchDuration)
        XCTAssertEqual(EventTargetRoute(kind: "target.app_control_batch_result"), .batchResult)
    }

    func testTheDevicePickerStillRoutesToTheGenericSelect() {
        XCTAssertEqual(EventTargetRoute(kind: "target.device_select"), .targetSelect)
        XCTAssertEqual(EventTargetRoute(kind: "target.child_select"), .targetSelect)
    }

    // MARK: - Request encoding

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAChoiceIsSentWithoutADuration() throws {
        let client = AgentClient(baseURL: "https://example.test")
        let request = try client.makeAppControlBatchRequest(
            continuationToken: "batch", choice: "block", duration: nil
        )
        let json = try body(request)
        XCTAssertEqual(json["continuation_token"] as? String, "batch")
        XCTAssertEqual(json["choice"] as? String, "block")
        XCTAssertNil(json["duration"], "an unanswered duration must be absent, not null-ish")
    }

    func testMinutesCarryTheirValue() throws {
        let client = AgentClient(baseURL: "https://example.test")
        let request = try client.makeAppControlBatchRequest(
            continuationToken: "batch", choice: nil, duration: .minutes(15)
        )
        let duration = try XCTUnwrap(try body(request)["duration"] as? [String: Any])
        XCTAssertEqual(duration["kind"] as? String, "minutes")
        XCTAssertEqual(duration["value"] as? Int, 15)
    }

    /// Permanent is an ANSWER with no minutes. Encoding it as a missing
    /// duration would make the backend ask again, forever.
    func testPermanentIsAnAnswerNotAnAbsence() throws {
        let client = AgentClient(baseURL: "https://example.test")
        let request = try client.makeAppControlBatchRequest(
            continuationToken: "batch", choice: nil, duration: .permanent
        )
        let duration = try XCTUnwrap(try body(request)["duration"] as? [String: Any])
        XCTAssertEqual(duration["kind"] as? String, "permanent")
        XCTAssertNil(duration["value"])
    }

    func testTheRequestTargetsTheBatchEndpoint() throws {
        let client = AgentClient(baseURL: "https://example.test")
        let request = try client.makeAppControlBatchRequest(
            continuationToken: "b", choice: nil, duration: nil
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.test/parent/agent/app-control-batch"
        )
    }

    // MARK: - Receipt rows

    private func rowsPayload() -> [[String: Any]] {
        [
            [
                "device_id": "ipad",
                "device_label": "Liam's iPad",
                "target_label": "YouTube",
                "status": "failed",
                "message": "YouTube is not available on this device",
            ],
            [
                "device_id": "phone",
                "device_label": "Liam's iPhone",
                "target_label": "YouTube",
                "status": "queued",
                "message": "Block command sent",
            ],
        ]
    }

    func testRowsDecodeEveryFieldTheBackendSends() throws {
        let rows = AppControlBatchReceiptRow.decode(rowsPayload())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].deviceId, "phone")
        XCTAssertEqual(rows[1].deviceLabel, "Liam's iPhone")
        XCTAssertEqual(rows[1].targetLabel, "YouTube")
        XCTAssertEqual(rows[1].status, .queued)
        XCTAssertEqual(rows[1].message, "Block command sent")
    }

    /// The order IS the parent's mental model of their own devices; re-sorting
    /// by outcome would make a three-device receipt unreadable.
    func testRowsKeepTheOrderTheBackendSent() {
        let rows = AppControlBatchReceiptRow.decode(rowsPayload())
        XCTAssertEqual(rows.map(\.deviceId), ["ipad", "phone"])
    }

    func testAnUnknownStatusIsTreatedAsFailedNotAsSuccess() {
        var payload = rowsPayload()
        payload[0]["status"] = "something_new"
        let rows = AppControlBatchReceiptRow.decode(payload)
        XCTAssertEqual(
            rows[0].status, .failed,
            "a status we cannot read must never be shown as success"
        )
    }

    func testAMalformedRowIsDroppedRatherThanRenderedBlank() {
        let rows = AppControlBatchReceiptRow.decode([["device_id": "only-an-id"]])
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Presentation

    func testQueuedAndFailedAreVisuallyDistinct() {
        XCTAssertEqual(AppControlBatchReceiptRow.Status.queued.iconName, "checkmark.circle.fill")
        XCTAssertEqual(AppControlBatchReceiptRow.Status.failed.iconName, "xmark.octagon.fill")
        XCTAssertNotEqual(
            AppControlBatchReceiptRow.Status.queued.tint,
            AppControlBatchReceiptRow.Status.failed.tint
        )
    }

    /// The message is authored by the backend's allow-list. If it were ever
    /// empty the row must still read as something a parent understands, and
    /// never fall back to a raw code.
    func testAnEmptyMessageFallsBackToHumanCopyNotACode() {
        var payload = rowsPayload()
        payload[1]["message"] = ""
        let rows = AppControlBatchReceiptRow.decode(payload)
        XCTAssertFalse(rows[1].displayMessage.isEmpty)
        for leak in ["_missing", "_unavailable", "_required"] {
            XCTAssertFalse(rows[1].displayMessage.contains(leak))
        }
    }
}
