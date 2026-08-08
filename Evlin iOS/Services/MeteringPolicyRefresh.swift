import Foundation

/// Fetches current policy and hands it to the existing v2 recovery path.
/// This owns no state and introduces no additional coordinator.
enum MeteringPolicyRefresh {
    @MainActor
    static func now(
        childDeviceID: UUID,
        baseURL: URL
    ) async -> MeteringRecoveryOutcome? {
        do {
            let state = try await BigKidAPIClient(
                baseURL: baseURL,
                childId: childDeviceID
            ).fetchState()
            return try await MeteringProductionComposition
                .recoverFromSharedConfiguration(
                    role: .app,
                    runtime: state.earnedTimeRuntime,
                    usageCountingAllowed: state.effectiveUsageCountingAllowed,
                    expectedOwner: childDeviceID,
                    expectedBaseURL: baseURL
                )
        } catch {
            MeteringFlightRecorder.emitError(
                site: "meteringPolicyRefresh",
                error: error,
                detail: MeteringFlightRecorder.detail([
                    ("device", childDeviceID.uuidString),
                ])
            )
            return nil
        }
    }
}
