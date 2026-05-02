import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

/// Reports free-play consumption to the backend in 5-minute chunks.
/// Called from a `DeviceActivityMonitor` extension event handler that
/// fires when the kid hits the configured threshold while in free-play.
@MainActor
final class BigKidTimeReporter: ObservableObject {
    static let chunkMinutes = 5
    private let client: BigKidAPIClient

    init(client: BigKidAPIClient) { self.client = client }

    func reportChunk() async {
        do {
            try await client.reportTimeUse(minutesUsed: Self.chunkMinutes)
        } catch {
            print("[BigKidTimeReporter] chunk report failed: \(error)")
        }
    }
}
