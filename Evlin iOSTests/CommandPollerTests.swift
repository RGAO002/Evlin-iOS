import XCTest
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

    override func setUp() async throws {
        savedDeviceIDProvider = poller.childDeviceIDProvider
        savedPollOverride = poller.oneShotPollOverride
    }

    override func tearDown() async throws {
        poller.childDeviceIDProvider = savedDeviceIDProvider
        poller.oneShotPollOverride = savedPollOverride
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

    /// No paired child device id → safe no-op. A backgrounded push on a device
    /// that isn't a paired child must not poll (and must not crash).
    func testPollOnceForCurrentDeviceIsNoOpWhenNoDeviceID() async {
        poller.childDeviceIDProvider = { nil }

        var didPoll = false
        poller.oneShotPollOverride = { _, _ in didPoll = true }

        await poller.pollOnceForCurrentDevice()

        XCTAssertFalse(didPoll, "With no child device id the poll path must not run")
    }
}
