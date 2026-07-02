import XCTest
@testable import Evlin_iOS

final class ScreenTimeEventUploaderTests: XCTestCase {

    private func line(ts: String, emitter: ScreenTimeEvent.Emitter = .kidExtension) -> String {
        ScreenTimeEvent(
            ts: ts, emitter: emitter, deviceID: nil,
            dayKey: "2026-07-01@America/New_York",
            kind: .lock, source: .earnedPool, app: "device-wide",
            reason: "pool_exhausted", nums: nil, transition: nil,
            policyGen: nil, corrID: nil
        ).jsonLine()
    }

    // 1) same line → same hash; different line → different hash; 64-hex, no prefix
    func test_lineHash_deterministic() {
        let l = line(ts: "2026-07-01T20:55:00Z")
        XCTAssertEqual(ScreenTimeEventUploader.lineHash(l), ScreenTimeEventUploader.lineHash(l))
        XCTAssertNotEqual(ScreenTimeEventUploader.lineHash(l),
                          ScreenTimeEventUploader.lineHash(line(ts: "2026-07-01T20:56:00Z")))
        XCTAssertEqual(ScreenTimeEventUploader.lineHash(l).count, 64)
    }

    // 1b) client_event_id embeds the uploading device — identical lines from two
    //     devices must NOT collide (cross-device dedupe would eat one device's chain)
    func test_clientEventID_embedsDevice() {
        let l = line(ts: "2026-07-01T20:55:00Z")
        let idA = ScreenTimeEventUploader.clientEventID(deviceID: "DEV-A", line: l)
        let idB = ScreenTimeEventUploader.clientEventID(deviceID: "DEV-B", line: l)
        XCTAssertNotEqual(idA, idB)
        XCTAssertEqual(idA, "line:DEV-A:" + ScreenTimeEventUploader.lineHash(l))
        XCTAssertLessThanOrEqual(idA.count, 128)  // backend column limit
    }

    // 2) no watermark → everything pending
    func test_pendingLines_noWatermark_returnsAll() {
        let all = [line(ts: "T1"), line(ts: "T2")]
        XCTAssertEqual(ScreenTimeEventUploader.pendingLines(all: all, lastUploadedHash: nil), all)
    }

    // 3) watermark in buffer → only lines after it
    func test_pendingLines_afterWatermark() {
        let a = line(ts: "T1"), b = line(ts: "T2"), c = line(ts: "T3")
        let mark = ScreenTimeEventUploader.lineHash(b)
        XCTAssertEqual(ScreenTimeEventUploader.pendingLines(all: [a, b, c], lastUploadedHash: mark), [c])
    }

    // 4) watermark rotated out of the capped buffer → re-upload all (server dedupes)
    func test_pendingLines_rotatedWatermark_returnsAll() {
        let all = [line(ts: "T5"), line(ts: "T6")]
        XCTAssertEqual(
            ScreenTimeEventUploader.pendingLines(all: all, lastUploadedHash: "0123deadbeef"), all)
    }

    // 5) emitter → device id attribution
    func test_deviceID_mapping() {
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .parentApp, parentID: "P", childID: "C"), "P")
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .kidApp, parentID: "P", childID: "C"), "C")
        XCTAssertEqual(ScreenTimeEventUploader.deviceID(for: .kidExtension, parentID: "P", childID: "C"), "C")
        XCTAssertNil(ScreenTimeEventUploader.deviceID(for: .kidExtension, parentID: "P", childID: nil))
        XCTAssertNil(ScreenTimeEventUploader.deviceID(for: .backend, parentID: "P", childID: "C"))
    }

    // 6) grouping: kid + parent events split into per-device payloads; snake_case keys
    func test_groupedPayloads_groupsByEmitterAndBuildsPayload() {
        let kid = line(ts: "2026-07-01T20:55:00Z", emitter: .kidExtension)
        let parent = line(ts: "2026-07-01T20:56:00Z", emitter: .parentApp)
        let groups = ScreenTimeEventUploader.groupedPayloads(
            lines: [kid, parent], parentID: "P-ID", childID: "C-ID")
        XCTAssertEqual(Set(groups.keys), ["P-ID", "C-ID"])
        let payload = groups["C-ID"]![0]
        XCTAssertEqual(payload["emitter"] as? String, "kid_extension")
        XCTAssertEqual(payload["kind"] as? String, "lock")
        XCTAssertEqual(payload["source"] as? String, "earnedPool")
        XCTAssertEqual(payload["day_key"] as? String, "2026-07-01@America/New_York")
        XCTAssertEqual(payload["client_event_id"] as? String,
                       ScreenTimeEventUploader.clientEventID(deviceID: "C-ID", line: kid))
    }

    // 7) unattributable lines are skipped, not crashed on
    func test_groupedPayloads_skipsUnattributable() {
        let kid = line(ts: "T1", emitter: .kidExtension)
        let groups = ScreenTimeEventUploader.groupedPayloads(
            lines: [kid, "not json"], parentID: nil, childID: nil)
        XCTAssertTrue(groups.isEmpty)
    }

    // 8) request shape: path, header == body device_id
    func test_makeRequest_shape() throws {
        let req = try ScreenTimeEventUploader.makeRequest(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            deviceID: "DEV-1",
            events: [["kind": "lock", "client_event_id": "line:x"]])
        XCTAssertEqual(req.url?.path, "/api/v1/device/screen-time/events")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Evlin-Device-ID"), "DEV-1")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["device_id"] as? String, "DEV-1")
        XCTAssertEqual((body["events"] as? [[String: Any]])?.count, 1)
    }
}
