import XCTest
@testable import Evlin_iOS

/// Decodes the backend GET /family aggregate (app/schemas/profile.py FamilyDTO)
/// into the iOS Codable DTOs, asserting the snake_case wire shape maps exactly,
/// plus DeviceModelMap fallback + DeviceInfoProvider field names (spec §6.1).
final class FamilyStoreTests: XCTestCase {
    // FamilyStore is `@MainActor @Observable` and owns APIClient, which uses
    // @Published. Under this project's current Swift back-deploy runtime,
    // releasing that graph inside XCTest can abort in the isolated-deinit shim.
    // Existing tests use the same process-lifetime retention workaround for
    // AuthService/ChatViewModel; keep this test focused on cache behavior.
    @MainActor private static var retainedStores: [FamilyStore] = []

    @MainActor private func makeRetainedFamilyStore() -> FamilyStore {
        let store = FamilyStore(api: APIClient(baseURL: "http://preview.local"))
        Self.retainedStores.append(store)
        return store
    }

    @MainActor
    func testIdentityBackfillFillsMissingFamilyWhenDeviceAlreadyExists() {
        let suite = "FamilyStoreTests.identity-backfill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let existingDeviceID = UUID()
        let familyID = UUID()
        defaults.set(existingDeviceID.uuidString, forKey: "evlin.childDeviceID")

        FamilyIdentityBackfill.apply(
            familyID: familyID.uuidString,
            children: [],
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.string(forKey: "evlin.childDeviceID"),
            existingDeviceID.uuidString
        )
        XCTAssertEqual(defaults.string(forKey: "evlin.familyID"), familyID.uuidString)
    }


    /// A representative GET /family response: one family with two parents
    /// (owner + co-parent), two children (one with a photo avatar + a child
    /// device, one with an emoji avatar + no device), and one parent device.
    private let familyJSON = """
    {
      "family": {
        "id": "11111111-1111-1111-1111-111111111111",
        "display_name": "The Test Family",
        "protection_mode": "guided",
        "smart_mode": true,
        "owner_account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "members": [
          {
            "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "display_name": "Parent One",
            "is_owner": true,
            "avatar": { "kind": "emoji", "value": "🙂", "color": "#2563EB" }
          },
          {
            "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "display_name": "Parent Two",
            "is_owner": false,
            "avatar": { "kind": "preset", "value": "p3", "color": "#9333EA" }
          }
        ]
      },
      "children": [
        {
          "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
          "display_name": "Kid A",
          "age": 12,
          "gender": "female",
          "avatar": {
            "kind": "photo",
            "value": "",
            "color": "#2E7D32",
            "signed_url": "https://signed.example/families/f/children/c/a.jpg?exp=600",
            "expires_at": "2026-06-07T12:10:00Z"
          },
          "devices": [
            {
              "device_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
              "mode": "child",
              "label": "Kid iPhone",
              "device_model": "iPhone 13",
              "platform": "ios",
              "os_version": "17.2",
              "display": "iPhone 13 · iOS 17",
              "last_seen_at": "2026-06-07T12:00:00Z",
              "online": true,
              "is_self": false
            }
          ]
        },
        {
          "id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
          "display_name": "Kid B",
          "age": null,
          "gender": null,
          "avatar": { "kind": "emoji", "value": "🧒", "color": "#F59E0B" },
          "devices": []
        }
      ],
      "parent_devices": [
        {
          "device_id": "ffffffff-ffff-ffff-ffff-ffffffffffff",
          "mode": "parent",
          "label": "My iPhone",
          "device_model": "iPhone 15 Pro",
          "platform": "ios",
          "os_version": "18.4",
          "display": "iPhone 15 Pro · iOS 18",
          "last_seen_at": "2026-06-07T12:05:00Z",
          "online": true,
          "is_self": true
        }
      ]
    }
    """

    func testDecodesFamilyAggregate() throws {
        let data = Data(familyJSON.utf8)
        let dto = try JSONDecoder().decode(FamilyDTO.self, from: data)

        // Family block
        XCTAssertEqual(dto.family.display_name, "The Test Family")
        XCTAssertEqual(dto.family.protection_mode, "guided")
        XCTAssertTrue(dto.family.smart_mode)
        XCTAssertEqual(dto.family.owner_account_id, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

        // Parents (members)
        XCTAssertEqual(dto.family.members.count, 2)
        let owner = dto.family.members[0]
        XCTAssertEqual(owner.display_name, "Parent One")
        XCTAssertTrue(owner.is_owner)
        XCTAssertEqual(owner.avatar.kind, "emoji")
        XCTAssertEqual(owner.avatar.value, "🙂")
        XCTAssertEqual(owner.id, owner.account_id)   // Identifiable
        XCTAssertFalse(dto.family.members[1].is_owner)

        // Children
        XCTAssertEqual(dto.children.count, 2)
        let kidA = dto.children[0]
        XCTAssertEqual(kidA.display_name, "Kid A")
        XCTAssertEqual(kidA.age, 12)
        XCTAssertEqual(kidA.gender, "female")
        XCTAssertEqual(kidA.id, "cccccccc-cccc-cccc-cccc-cccccccccccc")

        // Photo avatar → signed URL present
        XCTAssertEqual(kidA.avatar.kind, "photo")
        XCTAssertEqual(kidA.avatar.signed_url,
                       "https://signed.example/families/f/children/c/a.jpg?exp=600")
        XCTAssertEqual(kidA.avatar.expires_at, "2026-06-07T12:10:00Z")

        // Child device — server-composed display + online flag
        XCTAssertEqual(kidA.devices.count, 1)
        let kidDevice = kidA.devices[0]
        XCTAssertEqual(kidDevice.mode, "child")
        XCTAssertEqual(kidDevice.device_model, "iPhone 13")
        XCTAssertEqual(kidDevice.display, "iPhone 13 · iOS 17")
        XCTAssertTrue(kidDevice.online)
        XCTAssertFalse(kidDevice.is_self)
        XCTAssertEqual(kidDevice.id, kidDevice.device_id)   // Identifiable

        // Second child: null age/gender, emoji avatar, no devices
        let kidB = dto.children[1]
        XCTAssertNil(kidB.age)
        XCTAssertNil(kidB.gender)
        XCTAssertEqual(kidB.avatar.kind, "emoji")
        XCTAssertNil(kidB.avatar.signed_url)
        XCTAssertTrue(kidB.devices.isEmpty)

        // Parent devices
        XCTAssertEqual(dto.parent_devices.count, 1)
        let parentDevice = dto.parent_devices[0]
        XCTAssertEqual(parentDevice.mode, "parent")
        XCTAssertTrue(parentDevice.is_self)
        XCTAssertEqual(parentDevice.display, "iPhone 15 Pro · iOS 18")
    }

    /// MeProfileResponse shares the same FamilyBlock/Child/Device DTOs and adds
    /// the §15.7 account block (decoded into the Plan-1 AuthAccountDTO). The
    /// backend may echo extra account keys (email/provider) — decode ignores them.
    func testDecodesMeProfileAggregateWithAccountBlock() throws {
        let json = """
        {
          "account": {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "family_id": "11111111-1111-1111-1111-111111111111",
            "display_name": "Parent One",
            "needs_family": false,
            "email": "p@example.com",
            "provider": "apple"
          },
          "parent_profile": {
            "id": "99999999-9999-9999-9999-999999999999",
            "display_name": "Parent One",
            "avatar": { "kind": "emoji", "value": "🙂", "color": "#2563EB" }
          },
          "family": {
            "id": "11111111-1111-1111-1111-111111111111",
            "display_name": "The Test Family",
            "protection_mode": "guided",
            "smart_mode": false,
            "owner_account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "members": []
          },
          "children": [],
          "parent_devices": []
        }
        """
        let dto = try JSONDecoder().decode(MeProfileResponseDTO.self, from: Data(json.utf8))
        // §15.7 — membership read off the account block, NOT a separate field.
        XCTAssertEqual(dto.account.familyID?.uuidString.lowercased(),
                       "11111111-1111-1111-1111-111111111111")
        XCTAssertFalse(dto.account.needsFamily)
        XCTAssertEqual(dto.account.displayName, "Parent One")
        XCTAssertEqual(dto.parent_profile.avatar.value, "🙂")
        XCTAssertEqual(dto.family?.display_name, "The Test Family")
        XCTAssertTrue(dto.children.isEmpty)
    }

    func testChildProfileMapsEarnedSummaryToRemainingTimeDisplay() throws {
        let dto = ChildDTO(
            id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            display_name: "Kid A",
            age: 12,
            gender: "female",
            avatar: AvatarDTO(kind: "emoji", value: "🧒", color: "#2E7D32", signed_url: nil, expires_at: nil),
            devices: []
        )
        let summary = APIClient.EarnedSummaryDTO(
            child_profile_id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"),
            state: "ok",
            earned_minutes: 120,
            used_minutes: 90,
            remaining_minutes: 30,
            override_active: false,
            updated_at: nil,
            countdown_label: nil,
            daily_pool_minutes: 120,
            device_estimates: nil
        )

        let profile = ChildProfile(dto: dto, earnedSummary: summary)

        XCTAssertEqual(profile.timeLeft, "30m left")
        XCTAssertEqual(profile.timePct, 0.25, accuracy: 0.001)
    }

    @MainActor
    func testFamilyStoreEarnedSummaryCacheUsesLatestSummary() {
        let store = makeRetainedFamilyStore()
        let childID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let stale = APIClient.EarnedSummaryDTO(
            child_profile_id: UUID(uuidString: childID),
            state: "exhausted",
            earned_minutes: 90,
            used_minutes: 90,
            remaining_minutes: 0,
            override_active: false,
            updated_at: nil,
            countdown_label: "Time's up for today",
            daily_pool_minutes: 90,
            device_estimates: nil
        )
        let fresh = APIClient.EarnedSummaryDTO(
            child_profile_id: UUID(uuidString: childID),
            state: "ok",
            earned_minutes: 90,
            used_minutes: 0,
            remaining_minutes: 90,
            override_active: false,
            updated_at: nil,
            countdown_label: "1h 30m left",
            daily_pool_minutes: 90,
            device_estimates: nil
        )

        store.cacheEarnedSummary(stale, forChildID: childID)
        store.cacheEarnedSummary(fresh, forChildID: childID)

        XCTAssertEqual(store.earnedSummary(forChildID: childID)?.countdown_label, "1h 30m left")
        XCTAssertEqual(store.earnedSummary(forChildID: childID)?.remaining_minutes, 90)
    }

    /// §15.8 R2 / PIN (B): the pending co-parent poll path — family=null,
    /// pending_invite populated, account.needs_family == true.
    func testDecodesFamilyMePendingCoparent() throws {
        let json = """
        {
          "account": {
            "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "family_id": null,
            "display_name": "Co Parent",
            "needs_family": true
          },
          "family": null,
          "pending_invite": { "code": "ABCD2345", "status": "pending" }
        }
        """
        let dto = try JSONDecoder().decode(FamilyMeResponseDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.account.familyID)
        XCTAssertTrue(dto.account.needsFamily)
        XCTAssertNil(dto.family)
        XCTAssertEqual(dto.pending_invite?.code, "ABCD2345")
        XCTAssertEqual(dto.pending_invite?.status, "pending")
    }

    // MARK: - DeviceModelMap / DeviceInfoProvider (spec §1.7)

    func testDeviceModelMapKnownAndFallback() {
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone12,1"), "iPhone 11")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone14,6"), "iPhone SE (3rd gen)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone16,1"), "iPhone 15 Pro")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone17,1"), "iPhone 16 Pro")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone17,5"), "iPhone 16e")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone18,1"), "iPhone 17 Pro")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone18,2"), "iPhone 17 Pro Max")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone18,3"), "iPhone 17")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone18,4"), "iPhone Air")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone18,5"), "iPhone 17e")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad13,1"), "iPad Air (4th gen)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad15,7"), "iPad (A16)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad15,3"), "iPad Air 11'' (M3)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad16,8"), "iPad Air 11'' (M4)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad17,1"), "iPad Pro 11'' (M5)")
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPad16,1"), "iPad mini (A17 Pro)")
        // Unmapped raw id falls back to the raw id verbatim.
        XCTAssertEqual(DeviceModelMap.friendlyName(for: "iPhone99,9"), "iPhone99,9")
    }

    func testDeviceItemMapsRawBackendModelIdentifierForLegacyRows() {
        let dto = EnrolledDeviceDTO(
            device_id: "device-1",
            mode: "child",
            label: nil,
            device_model: "iPhone12,1",
            platform: "ios",
            os_version: "18.5",
            display: "iPhone12,1 · iOS 18",
            last_seen_at: nil,
            online: false,
            is_self: false
        )

        let item = DeviceItem(dto: dto)

        XCTAssertEqual(item.name, "iPhone 11")
        XCTAssertEqual(item.detail, "iPhone 11 · iOS 18.5")
    }

    func testDeviceItemMapsIPadModelIdentifierForEnrolledDeviceRows() {
        let dto = EnrolledDeviceDTO(
            device_id: "device-1",
            mode: "child",
            label: nil,
            device_model: "iPad13,1",
            platform: "ios",
            os_version: "18.5",
            display: "iPad13,1 · iOS 18",
            last_seen_at: nil,
            online: false,
            is_self: false
        )

        let item = DeviceItem(dto: dto)

        XCTAssertEqual(item.name, "iPad Air (4th gen)")
        XCTAssertEqual(item.detail, "iPad Air (4th gen) · iOS 18.5")
    }

    func testDeviceItemMapsLatestIPhoneModelIdentifierForEnrolledDeviceRows() {
        let dto = EnrolledDeviceDTO(
            device_id: "device-1",
            mode: "child",
            label: nil,
            device_model: "iPhone18,3",
            platform: "ios",
            os_version: "26.6.1",
            display: "iPhone18,3 · iOS 26",
            last_seen_at: nil,
            online: false,
            is_self: false
        )

        let item = DeviceItem(dto: dto)

        XCTAssertEqual(item.name, "iPhone 17")
        XCTAssertEqual(item.detail, "iPhone 17 · iOS 26.6.1")
    }

    func testDeviceItemMapsServerConfirmedMeteringReadiness() {
        let dto = EnrolledDeviceDTO(
            device_id: "device-ready",
            mode: "child",
            label: "Kid iPhone",
            device_model: "iPhone18,3",
            platform: "ios",
            os_version: "26.1",
            display: "iPhone 17 · iOS 26",
            last_seen_at: nil,
            online: true,
            is_self: false,
            metering_ready: true
        )

        let item = DeviceItem(dto: dto)

        XCTAssertTrue(item.meteringReady)
    }

    func testDeviceItemDefaultsMeteringReadinessToFalseForOlderResponses() throws {
        let data = Data("""
        {
          "device_id": "legacy-device",
          "mode": "child",
          "label": "Older build",
          "device_model": "iPhone12,1",
          "platform": "ios",
          "os_version": "18.5",
          "display": "iPhone 11 · iOS 18",
          "last_seen_at": null,
          "online": true,
          "is_self": false
        }
        """.utf8)

        let dto = try JSONDecoder().decode(EnrolledDeviceDTO.self, from: data)
        let item = DeviceItem(dto: dto)

        XCTAssertFalse(item.meteringReady)
    }

    func testDeviceInfoProviderFieldNames() {
        let payload = DeviceInfoProvider.current()
        XCTAssertEqual(payload.platform, "ios")
        XCTAssertFalse(payload.device_model_id.isEmpty)
        XCTAssertFalse(payload.os_version.isEmpty)
        // device_model is the friendly map of the raw id (or the raw id itself).
        XCTAssertEqual(payload.device_model,
                       DeviceModelMap.friendlyName(for: payload.device_model_id))
        // The JSON keys are the §1.7 snake_case Device columns.
        let encoded = try! JSONEncoder().encode(payload)
        let obj = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertNotNil(obj["device_model"])
        XCTAssertNotNil(obj["device_model_id"])
        XCTAssertNotNil(obj["platform"])
        XCTAssertNotNil(obj["os_version"])
    }
}
