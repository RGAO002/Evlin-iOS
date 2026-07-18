import Foundation

nonisolated enum EarnedMeteringCallbackOutcome: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
}

/// Names-only DeviceActivity callbacks cross this boundary before they can
/// affect durable metering state. Network delivery and shield effects are
/// intentionally outside this type.
nonisolated final class EarnedMeteringCallback: @unchecked Sendable {
    static let defaultJitterSeconds = 30
    static let maximumJitterSeconds = 60

    private let store: DeviceEpochStore
    private let clock: any MeteringClock
    private let jitterSeconds: Int?

    init(
        store: DeviceEpochStore = .shared,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        jitterSeconds: Int = defaultJitterSeconds
    ) {
        self.store = store
        self.clock = clock
        self.jitterSeconds = (0...Self.maximumJitterSeconds).contains(jitterSeconds) ? jitterSeconds : nil
    }

    func handle(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let jitterSeconds else { return .discarded(reason: "invalid_jitter") }
        guard let parsed = MeteringRouteNamespace.parse(
            activityName: callback.activityName,
            eventName: callback.eventName
        ) else {
            return .discarded(reason: "malformed_route")
        }

        let result = try store.enqueueAuthorizedV2Callback(
            MeteringAuthorizedCallbackInput(
                routeID: parsed.routeID,
                activityName: callback.activityName,
                eventName: callback.eventName,
                namespace: MeteringRouteNamespace.prefix,
                thresholdMinutes: parsed.thresholdMinutes,
                observedAt: callback.observedAt,
                now: clock.now,
                jitterSeconds: jitterSeconds
            ),
            owner: expectedOwnerChildDeviceID
        )
        switch result {
        case .queued(let sampleWorkID): return .queued(sampleWorkID: sampleWorkID)
        case .discarded(let reason): return .discarded(reason: reason)
        }
    }
}
