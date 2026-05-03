import Combine
import Foundation
import SwiftUI

/// Polls `/child/state` every 60s while app is foregrounded; refreshes
/// immediately on `scenePhase == .active` transitions. Hands snapshots
/// to `BigKidState` via the `apply(_:)` method.
@MainActor
final class BigKidStatePoller: ObservableObject {
    @Published var lastError: String?
    @Published var lastFetchedAt: Date?

    private let client: BigKidAPIClient
    private let state: BigKidState
    private var task: Task<Void, Never>?

    init(client: BigKidAPIClient, state: BigKidState) {
        self.client = client
        self.state = state
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Force an immediate refresh (e.g. on scenePhase change or after a write).
    func refreshNow() async {
        await fetchOnce()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await fetchOnce()
            try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60s
        }
    }

    private func fetchOnce() async {
        do {
            let snapshot = try await client.fetchState()
            state.apply(snapshot)
            lastFetchedAt = Date()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
