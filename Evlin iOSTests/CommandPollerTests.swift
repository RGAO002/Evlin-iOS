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

    override func setUp() async throws {
        savedDeviceIDProvider = poller.childDeviceIDProvider
        savedPollOverride = poller.oneShotPollOverride
        savedPollCommandsOverride = poller.pollCommandsOverride
    }

    override func tearDown() async throws {
        poller.childDeviceIDProvider = savedDeviceIDProvider
        poller.oneShotPollOverride = savedPollOverride
        poller.pollCommandsOverride = savedPollCommandsOverride
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
