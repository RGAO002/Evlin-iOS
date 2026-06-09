import XCTest
@testable import Evlin_iOS

final class ChildProfileMappingTests: XCTestCase {

    private func avatar() -> AvatarDTO {
        AvatarDTO(kind: "emoji", value: "🧒", color: "#2E7D32", signed_url: nil, expires_at: nil)
    }

    private func device(online: Bool, lastSeen: String?) -> EnrolledDeviceDTO {
        EnrolledDeviceDTO(device_id: "d1", mode: "child", label: "iPhone",
                          device_model: nil, platform: nil, os_version: nil,
                          display: "Liam's iPhone", last_seen_at: lastSeen,
                          online: online, is_self: false)
    }

    func test_init_does_not_fabricate_unlocked_2h() {
        let dto = ChildDTO(id: "abc", display_name: "Sam", age: 8, gender: nil,
                           avatar: avatar(), devices: [])
        let p = ChildProfile(dto: dto)
        // No fabricated time-budget: the old code set timeLeft="2h"/timePct=1.0.
        XCTAssertEqual(p.timeLeft, "")
        XCTAssertEqual(p.timePct, 0)
        // No device → no control line at all.
        XCTAssertNil(p.deviceStatusLine)
    }

    func test_init_online_device_shows_online_line() {
        let dto = ChildDTO(id: "abc", display_name: "Sam", age: 8, gender: nil,
                           avatar: avatar(), devices: [device(online: true, lastSeen: nil)])
        let p = ChildProfile(dto: dto)
        XCTAssertEqual(p.deviceStatusLine, "Online")
    }

    func test_init_offline_device_shows_last_seen_when_present() {
        let dto = ChildDTO(id: "abc", display_name: "Sam", age: 8, gender: nil,
                           avatar: avatar(),
                           devices: [device(online: false, lastSeen: "2026-06-09T10:00:00Z")])
        let p = ChildProfile(dto: dto)
        XCTAssertEqual(p.deviceStatusLine, "Last seen recently")
    }

    func test_init_offline_device_no_last_seen_shows_offline() {
        let dto = ChildDTO(id: "abc", display_name: "Sam", age: 8, gender: nil,
                           avatar: avatar(), devices: [device(online: false, lastSeen: nil)])
        let p = ChildProfile(dto: dto)
        XCTAssertEqual(p.deviceStatusLine, "Offline")
    }
}
