import XCTest
@testable import Evlin_iOS

/// The tri-state badge's compatibility rule: old servers omit
/// `metering_state`, and their boolean must map to exactly the visuals the
/// badge showed before the field existed — armed reads ACTIVE, everything
/// else SYNCING. A new server's explicit state passes through untouched.
final class DeviceRowMeteringBadgeTests: XCTestCase {

    private func dto(ready: Bool?, state: String?) -> EnrolledDeviceDTO {
        EnrolledDeviceDTO(
            device_id: UUID().uuidString,
            mode: "child",
            label: "iPad",
            device_model: "iPad13,18",
            platform: "ios",
            os_version: "26.0",
            display: nil,
            last_seen_at: nil,
            online: true,
            is_self: false,
            metering_ready: ready,
            metering_state: state
        )
    }

    func test_oldServerBooleanKeepsTheHistoricalVisuals() {
        XCTAssertEqual(
            DeviceItem(dto: dto(ready: true, state: nil)).meteringState,
            "active_delivering"
        )
        XCTAssertEqual(
            DeviceItem(dto: dto(ready: false, state: nil)).meteringState,
            "syncing"
        )
        XCTAssertEqual(
            DeviceItem(dto: dto(ready: nil, state: nil)).meteringState,
            "syncing"
        )
    }

    func test_newServerStatePassesThroughEvenWhenBooleanDisagrees() {
        // The tri-state is strictly more honest than the boolean: an armed
        // device with a standing red is ready=true but action_required — the
        // state must win or the new badge can never say ATTENTION.
        XCTAssertEqual(
            DeviceItem(
                dto: dto(ready: true, state: "action_required")
            ).meteringState,
            "action_required"
        )
        XCTAssertEqual(
            DeviceItem(
                dto: dto(ready: true, state: "armed_awaiting_traffic")
            ).meteringState,
            "armed_awaiting_traffic"
        )
    }
}
