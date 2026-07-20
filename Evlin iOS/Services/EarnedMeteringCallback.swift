import Foundation

/// The Phase 3 physical-time upper bound shared by earned and per-app callbacks.
/// It deliberately has no lower-bound age check, so delayed valid callbacks stay
/// eligible while impossible immediate thresholds are rejected.
nonisolated enum MeteringCallbackPhysicalTime {
    static let defaultJitterSeconds = MeteringEpochContract.defaultJitterSeconds
    static let maximumJitterSeconds = MeteringEpochContract.maximumJitterSeconds

    static func allows(
        adjustedEstimateMinutes: Int,
        baseAcceptedMinutes: Int,
        startedAt: Date,
        observedAt: Date,
        jitterSeconds: Int = defaultJitterSeconds
    ) -> Bool {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let epoch = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return MeteringEpochContract.callbackVerdict(
            MeteringCallbackInput(
                activeEpochID: epoch,
                callbackEpochID: epoch,
                activeOwnerDeviceID: owner,
                callbackOwnerDeviceID: owner,
                activeUsageDate: "physical-time",
                callbackUsageDate: "physical-time",
                activePolicyRevision: "physical-time",
                callbackPolicyRevision: "physical-time",
                expectedEventNamespace: "physical-time",
                callbackEventNamespace: "physical-time",
                adjustedEstimateMinutes: adjustedEstimateMinutes,
                baseAcceptedMinutes: baseAcceptedMinutes,
                startedAt: startedAt,
                callbackAt: observedAt,
                jitterSeconds: jitterSeconds
            )
        ) == .accept
    }
}

nonisolated enum EarnedMeteringCallbackOutcome: Equatable, Sendable {
    case queued(sampleWorkID: UUID)
    case discarded(reason: String)
}

/// Names-only DeviceActivity callbacks cross this boundary before they can
/// affect durable metering state. Network delivery and shield effects are
/// intentionally outside this type.
nonisolated final class EarnedMeteringCallback: @unchecked Sendable {
    static let defaultJitterSeconds = MeteringCallbackPhysicalTime.defaultJitterSeconds
    static let maximumJitterSeconds = MeteringCallbackPhysicalTime.maximumJitterSeconds

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
        expectedOwnerChildDeviceID: UUID,
        preparedShieldReference: EarnedShieldReference? = nil
    ) throws -> EarnedMeteringCallbackOutcome {
        guard let input = callbackInput(callback) else {
            return .discarded(reason: jitterSeconds == nil ? "invalid_jitter" : "malformed_route")
        }

        let result = try store.enqueueAuthorizedV2Callback(
            input,
            owner: expectedOwnerChildDeviceID,
            preparedShieldReference: preparedShieldReference
        )
        switch result {
        case .queued(let sampleWorkID): return .queued(sampleWorkID: sampleWorkID)
        case .discarded(let reason): return .discarded(reason: reason)
        }
    }

    func terminalCandidate(
        _ callback: MeteringAppleCallback,
        expectedOwnerChildDeviceID: UUID
    ) throws -> MeteringTerminalShieldCandidate? {
        guard let input = callbackInput(callback) else { return nil }
        return try store.terminalShieldCandidate(
            input,
            owner: expectedOwnerChildDeviceID
        )
    }

    private func callbackInput(
        _ callback: MeteringAppleCallback
    ) -> MeteringAuthorizedCallbackInput? {
        guard let jitterSeconds,
              let parsed = MeteringRouteNamespace.parse(
                  activityName: callback.activityName,
                  eventName: callback.eventName
              )
        else { return nil }
        return MeteringAuthorizedCallbackInput(
            routeID: parsed.routeID,
            activityName: callback.activityName,
            eventName: callback.eventName,
            namespace: MeteringRouteNamespace.prefix,
            thresholdMinutes: parsed.thresholdMinutes,
            observedAt: callback.observedAt,
            now: clock.now,
            jitterSeconds: jitterSeconds
        )
    }
}
