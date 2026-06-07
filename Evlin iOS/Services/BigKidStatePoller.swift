import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// Broadcast by ChatViewModel after a successful /parent/agent/exec so
    /// any active BigKidStatePoller refreshes right away. Without this the
    /// kid would have to wait up to one poll interval to see a reflection
    /// the parent just confirmed in chat.
    static let bigKidStateInvalidated = Notification.Name("bigKidStateInvalidated")
}

/// Polls `/child/state` every 20s while app is foregrounded; refreshes
/// immediately on `scenePhase == .active` transitions and on the
/// `bigKidStateInvalidated` notification. Hands snapshots to
/// `BigKidState` via the `apply(_:)` method.
@MainActor
final class BigKidStatePoller: ObservableObject {
    @Published var lastError: String?
    @Published var lastFetchedAt: Date?

    /// Plan 8 (§15.3): set once the kid's family was deleted (terminal
    /// `410 family_removed`). After this the loop stops and the poller is inert
    /// — a deleted family must never keep polling or re-arm a lock.
    @Published private(set) var familyRemoved = false

    private let client: BigKidAPIClient
    private let state: BigKidState
    private var task: Task<Void, Never>?
    private var invalidationObserver: NSObjectProtocol?

    /// Reflection Lockdown glue. Runs after each state apply: reconciles the
    /// dedicated reflection ShieldRecord against the snapshot, schedules its
    /// DAM auto-removal, and records (never swallows) a schedule failure.
    private let reflectionLockApplier = ReflectionLockApplier(
        scheduler: LockScheduler(activityScheduler: DeviceActivityCenterScheduler()))

    /// Polling cadence. 20s is short enough that a kid sees a reflection
    /// landing within "a few seconds" without explicit triggering, while
    /// still being polite to the backend. The notification path covers
    /// the same-device parent→kid mode-toggle case more tightly.
    private static let pollIntervalNanoseconds: UInt64 = 20_000_000_000

    init(client: BigKidAPIClient, state: BigKidState) {
        self.client = client
        self.state = state
    }

    deinit {
        if let obs = invalidationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        if invalidationObserver == nil {
            invalidationObserver = NotificationCenter.default.addObserver(
                forName: .bigKidStateInvalidated, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshNow() }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let obs = invalidationObserver {
            NotificationCenter.default.removeObserver(obs)
            invalidationObserver = nil
        }
    }

    /// Force an immediate refresh (e.g. on scenePhase change or after a write).
    func refreshNow() async {
        await fetchOnce()
    }

    private func runLoop() async {
        while !Task.isCancelled && !familyRemoved {
            await fetchOnce()
            if familyRemoved { break }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    private func fetchOnce() async {
        do {
            let snapshot = try await client.fetchState()
            state.apply(snapshot)
            if let raw = UserDefaults.standard.string(forKey: CommandPoller.childDeviceIDDefaultsKey),
               let childID = UUID(uuidString: raw) {
                await reflectionLockApplier.reconcile(snapshot: snapshot, childID: childID)
            }
            lastFetchedAt = Date()
            lastError = nil
        } catch {
            // Plan 8 (§15.3): a terminal `410 family_removed` means this kid's
            // family was deleted. FAIL OPEN — release every Evlin shield/block,
            // clear the reflection sticky + reset pairing — then stop the loop so
            // a deleted family can never brick the kid in a permanent lock.
            if FamilyGoneDetector.isFamilyGone(error: error) {
                print("[BigKidStatePoller] family_removed → failing open")
                familyRemoved = true
                await FamilyGoneDetector.failOpen()
                lastError = nil
                stop()
                return
            }
            print("[BigKidStatePoller] fetchState failed: \(error)")
            lastError = Self.userFacingMessage(for: error)
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Trying to reconnect"
            default:
                return "Couldn't refresh"
            }
        }
        return "Couldn't refresh"
    }
}
