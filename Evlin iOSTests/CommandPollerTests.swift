import XCTest
import UIKit
@testable import Evlin_iOS

/// Hermetic coverage for `CommandPoller.pollOnceForCurrentDevice()` — the
/// one-shot poll entry point the APNs background remote-notification handler
/// calls (Task 9 / Phase 5 L2 silent-push delivery).
///
/// We can't fire a real APNs push or mint a device token in a unit test, so we
/// drive the poller through its injectable seams (`childDeviceIDProvider`,
/// `oneShotPollOverride`) instead of touching shared `UserDefaults` or the
/// network. The override stands in for the real `pollOnce()` network path so we
/// can assert the device-id → poll wiring without any I/O.
@MainActor
final class CommandPollerTests: XCTestCase {
    private let poller = CommandPoller.shared

    // The poller is a singleton; snapshot its seams so each test is isolated
    // and we don't bleed an injected provider into other suites.
    private var savedDeviceIDProvider: (() -> UUID?)!
    private var savedPollOverride: ((UUID, APIClient) async -> Void)?
    private var savedPollCommandsOverride: ((UUID, APIClient) async throws -> [PollCommandDTO])?
    private var savedLockedSetIDOverride: ((String, Data?) -> Void)?
    private var savedAfterRekey: ((String, String) async -> Void)?

    override func setUp() async throws {
        savedDeviceIDProvider = poller.childDeviceIDProvider
        savedPollOverride = poller.oneShotPollOverride
        savedPollCommandsOverride = poller.pollCommandsOverride
        savedLockedSetIDOverride = poller.saveLockedSetIDOverride
        savedAfterRekey = poller.afterRekeyShieldRecord
    }

    override func tearDown() async throws {
        poller.childDeviceIDProvider = savedDeviceIDProvider
        poller.oneShotPollOverride = savedPollOverride
        poller.pollCommandsOverride = savedPollCommandsOverride
        poller.saveLockedSetIDOverride = savedLockedSetIDOverride
        poller.afterRekeyShieldRecord = savedAfterRekey
    }

    private func earnedConfigCommand() throws -> PollCommandDTO {
        let json = """
        {
          "command_id": "11111111-0000-0000-0000-000000000001",
          "action": "earned_time_config",
          "tier": "earnedTime",
          "target": { "target_type": "earnedTime", "original_request": "" },
          "issued_at": "2026-07-12T10:00:00.000000+00:00",
          "earned_time_config": {
            "child_profile_id": "BBBBBBBB-0000-0000-0000-000000000001",
            "child_device_id": "CCCCCCCC-0000-0000-0000-000000000001",
            "effective_date": "2026-07-12",
            "usage_date": "2026-07-12",
            "timezone": "America/New_York",
            "daily_pool_minutes": 90,
            "device_cap_minutes": 60,
            "earned_bucket_minutes": 10,
            "selected_set": { "list_id": "AAAAAAAA-0000-0000-0000-000000000001" }
          }
        }
        """
        return try JSONDecoder().decode(PollCommandDTO.self, from: Data(json.utf8))
    }

    /// With a paired child device id present, the one-shot poll routes that
    /// exact id into the poll path (the same path the foreground timer drives).
    func testPollOnceForCurrentDeviceRoutesStoredDeviceIDIntoPollPath() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!
        poller.childDeviceIDProvider = { expectedID }

        var observedID: UUID?
        var callCount = 0
        poller.oneShotPollOverride = { deviceID, _ in
            observedID = deviceID
            callCount += 1
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(callCount, 1, "Expected exactly one poll for the paired device")
        XCTAssertEqual(observedID, expectedID, "Poll must run against the stored child device id")
    }

    /// APNs can deliver lock and unlock wakes close together. The old poller
    /// dropped a wake that arrived while `isPolling == true`, which left the
    /// second command queued until the app foregrounded/restarted. A concurrent
    /// wake must coalesce into one immediate follow-up poll.
    func testConcurrentOneShotPollIsCoalescedIntoFollowUpPoll() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000004")!
        poller.childDeviceIDProvider = { expectedID }

        var pollCount = 0
        poller.pollCommandsOverride = { [weak poller] deviceID, _ in
            XCTAssertEqual(deviceID, expectedID)
            pollCount += 1
            if pollCount == 1 {
                Task { @MainActor in
                    await poller?.pollOnceForCurrentDevice()
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return []
        }

        await poller.pollOnceForCurrentDevice()

        XCTAssertEqual(pollCount, 2, "Concurrent wake should trigger one follow-up poll, not get dropped")
    }

    func testDelayedFetchDiscardsCommandsWhenStoredIdentityChanges() async throws {
        let oldID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000010")!
        let newID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000011")!
        var currentID = oldID
        var resumeFetch: CheckedContinuation<[PollCommandDTO], Never>?
        var fetchCount = 0
        var saveCount = 0
        let store = EarnedTimeStore.shared
        store.removeAll()
        defer {
            poller.saveLockedSetIDOverride = nil
            store.removeAll()
        }
        poller.childDeviceIDProvider = { currentID }
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = { _, _ in saveCount += 1 }
        poller.pollCommandsOverride = { _, _ in
            fetchCount += 1
            if fetchCount == 1 {
                return await withCheckedContinuation { resumeFetch = $0 }
            }
            return []
        }

        let poll = Task { await poller.pollOnceForCurrentDevice() }
        while resumeFetch == nil { await Task.yield() }
        currentID = newID
        resumeFetch?.resume(returning: [try earnedConfigCommand()])
        await poll.value

        XCTAssertEqual(saveCount, 0)
        XCTAssertNil(store.poolMinutes)
        XCTAssertNil(store.capMinutes)
        XCTAssertEqual(fetchCount, 2)
    }

    func testEarnedConfigRollsBackPersistedRekeyWhenIdentityChangesAfterMutation() async throws {
        let oldID = UUID()
        let newID = UUID()
        var currentID = oldID
        var resumeRekey: CheckedContinuation<Void, Never>?
        var fetchCount = 0
        let store = EarnedTimeStore.shared
        store.removeAll()
        defer { store.removeAll() }
        let priorListID = UUID().uuidString
        let backendListID = "AAAAAAAA-0000-0000-0000-000000000001"
        store.saveLockedSetID(priorListID, tokenData: nil)
        store.poolMinutes = 75
        store.capMinutes = 50
        let priorRecord = ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: .savedList, targetKey: priorListID),
            tier: .savedList,
            targetKey: priorListID,
            displayName: "Locked Set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(),
            expiresAt: nil,
            originalRequest: "old family lock",
            targetChildID: oldID,
            sources: [.manual]
        )
        _ = await ActiveLockStore.shared.addShield(priorRecord)

        poller.childDeviceIDProvider = { currentID }
        poller.oneShotPollOverride = nil
        poller.saveLockedSetIDOverride = nil
        poller.pollCommandsOverride = { _, _ in
            fetchCount += 1
            return fetchCount == 1 ? [try self.earnedConfigCommand()] : []
        }
        poller.afterRekeyShieldRecord = { existing, replacement in
            XCTAssertEqual(existing, priorListID)
            XCTAssertEqual(replacement, backendListID)
            await withCheckedContinuation { resumeRekey = $0 }
        }

        let poll = Task { await poller.pollOnceForCurrentDevice() }
        while resumeRekey == nil { await Task.yield() }
        let mutated = await ActiveLockStore.shared.allCurrent().shields
        XCTAssertNil(mutated.first { $0.recordKey == priorRecord.recordKey })
        XCTAssertNotNil(mutated.first {
            $0.recordKey == ShieldRecord.makeRecordKey(tier: .savedList, targetKey: backendListID)
        })
        XCTAssertEqual(store.lockedSetID, priorListID)
        currentID = newID
        resumeRekey?.resume()
        await poll.value

        XCTAssertEqual(store.lockedSetID, priorListID)
        XCTAssertEqual(store.poolMinutes, 75)
        XCTAssertEqual(store.capMinutes, 50)
        let restored = await ActiveLockStore.shared.allCurrent().shields
        let restoredRecord = try? XCTUnwrap(
            restored.first { $0.recordKey == priorRecord.recordKey }
        )
        XCTAssertEqual(restoredRecord?.recordKey, priorRecord.recordKey)
        XCTAssertEqual(restoredRecord?.targetKey, priorRecord.targetKey)
        XCTAssertEqual(restoredRecord?.lastCommandID, priorRecord.lastCommandID)
        XCTAssertEqual(restoredRecord?.targetChildID, priorRecord.targetChildID)
        XCTAssertEqual(restoredRecord?.sources, priorRecord.sources)
        XCTAssertEqual(
            restoredRecord?.issuedAt.timeIntervalSince1970 ?? 0,
            priorRecord.issuedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertNil(restored.first {
            $0.recordKey == ShieldRecord.makeRecordKey(tier: .savedList, targetKey: backendListID)
        })
        _ = await ActiveLockStore.shared.unshieldAll()
    }

    /// No paired child device id → safe no-op. A backgrounded push on a device
    /// that isn't a paired child must not poll (and must not crash).
    func testPollOnceForCurrentDeviceIsNoOpWhenNoDeviceID() async {
        poller.childDeviceIDProvider = { nil }

        var didPoll = false
        poller.oneShotPollOverride = { _, _ in didPoll = true }

        await poller.pollOnceForCurrentDevice()

        XCTAssertFalse(didPoll, "With no child device id the poll path must not run")
    }

    /// APNs wakes are shared by command delivery, BigKid reflection state, and
    /// parent notification feed rows. The app delegate must invalidate both
    /// UI stores so foreground parent sessions see reflection/nudge notifications
    /// without relaunching or tapping the system banner.
    func testRemoteNotificationPollsCommandsAndInvalidatesBigKidState() async {
        let expectedID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000002")!
        poller.childDeviceIDProvider = { expectedID }

        let stateInvalidated = expectation(description: "BigKid state invalidated")
        let feedInvalidated = expectation(description: "notification feed invalidated")
        let completionCalled = expectation(description: "APNs completion called")
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .bigKidStateInvalidated,
            object: nil,
            queue: .main
        ) { _ in
            stateInvalidated.fulfill()
        }
        let feedObserver = NotificationCenter.default.addObserver(
            forName: .evlinNotificationFeedInvalidated,
            object: nil,
            queue: .main
        ) { _ in
            feedInvalidated.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(stateObserver)
            NotificationCenter.default.removeObserver(feedObserver)
        }

        var observedID: UUID?
        poller.oneShotPollOverride = { deviceID, _ in
            observedID = deviceID
        }

        let appDelegate = AppDelegate()
        appDelegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "aps": ["content-available": 1],
                "evlin": ["kind": "reflection_wake"]
            ]
        ) { result in
            XCTAssertEqual(result, .newData)
            completionCalled.fulfill()
        }

        await fulfillment(of: [stateInvalidated, feedInvalidated, completionCalled], timeout: 1.0)
        XCTAssertEqual(observedID, expectedID)
    }

    /// Reinstall/pairing race: APNs can produce a device token before the kid
    /// device has written `evlin.childDeviceID`. When that child id appears in
    /// K mode, the app must replay token upload + registration immediately.
    /// Parent mode must not do this, or the parent phone can overwrite the kid
    /// device row with the parent's APNs token.
    func testChildDeviceIDAvailabilityReplaysAPNsOnlyInChildMode() {
        var uploadCount = 0
        var registrationCount = 0

        AppDelegate.handleChildDeviceIDAvailability(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "parent",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(registrationCount, 0)

        AppDelegate.handleChildDeviceIDAvailability(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "child",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(registrationCount, 1)

        AppDelegate.handleChildDeviceIDAvailability(
            "",
            appMode: "child",
            uploadCachedToken: { uploadCount += 1 },
            registerForRemoteNotifications: { registrationCount += 1 }
        )
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(registrationCount, 1)

        XCTAssertTrue(AppDelegate.shouldReplayAPNsForChildDeviceID(
            "ABCDEF00-0000-0000-0000-000000000003",
            appMode: "child"
        ))
        XCTAssertFalse(AppDelegate.shouldReplayAPNsForChildDeviceID(
            "not-a-uuid",
            appMode: "child"
        ))
    }
}
