import Foundation

nonisolated protocol MeteringHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: MeteringHTTPTransport {}

nonisolated enum EpochSampleHTTPDisposition: Equatable, Sendable {
    case accepted(DeviceDaySnapshotDTO)
    case acceptedDuplicate
    case terminal(code: String, snapshot: DeviceDaySnapshotDTO?)
    case retry(code: String)
}

nonisolated enum EpochRegistrationHTTPDisposition: Equatable, Sendable {
    case registered(EpochRegistrationResponseDTO)
    case authoritativeBaseMismatch(EpochRegistrationConflictDTO)
    case terminal(code: String)
    case retry(code: String)
}

nonisolated enum EpochActivationHTTPDisposition: Equatable, Sendable {
    case acknowledged(EpochActivationResponseDTO)
    case terminal(code: String)
    case retry(code: String)
}

nonisolated enum MeteringEpochDeliveryError: Error, Equatable, Sendable {
    case malformedLane
    case malformedRequest
    case unexpectedHTTPStatus(Int)
}

nonisolated final class MeteringEpochDelivery: @unchecked Sendable {
    private let baseURL: URL
    private let store: DeviceEpochStore
    private let transport: any MeteringHTTPTransport
    private let clock: any MeteringClock
    private let legacySuiteName: String
#if DEBUG
    private let debugAfterLegacyImportReadback: (@Sendable () -> Void)?
#endif

    init(
        baseURL: URL,
        store: DeviceEpochStore = .shared,
        transport: any MeteringHTTPTransport,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        legacySuiteName: String = "group.com.evlin.ios"
    ) {
        self.baseURL = baseURL
        self.store = store
        self.transport = transport
        self.clock = clock
        self.legacySuiteName = legacySuiteName
#if DEBUG
        self.debugAfterLegacyImportReadback = nil
#endif
    }

#if DEBUG
    init(
        baseURL: URL,
        store: DeviceEpochStore = .shared,
        transport: any MeteringHTTPTransport,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        legacySuiteName: String = "group.com.evlin.ios",
        debugAfterLegacyImportReadback: @escaping @Sendable () -> Void
    ) {
        self.baseURL = baseURL
        self.store = store
        self.transport = transport
        self.clock = clock
        self.legacySuiteName = legacySuiteName
        self.debugAfterLegacyImportReadback = debugAfterLegacyImportReadback
    }
#endif

    func enqueueV1(_ request: EpochSampleRequestDTO, owner: UUID) throws {
        guard request.lane == .v1 else { throw MeteringEpochDeliveryError.malformedLane }
        let now = clock.now
        try store.transaction(expectedOwner: owner) { state in
            guard !state.sampleWork.values.contains(where: {
                $0.ownerChildDeviceID == owner && $0.request.clientSampleID == request.clientSampleID
            }) else { return }
            let workID = UUID()
            state.sampleWork[workID] = EpochSampleWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: nil,
                routeID: nil,
                request: request,
                authorization: .legacyDeliverable,
                claim: nil,
                retry: pendingRetry(at: now),
                createdAt: now
            )
        }
    }

    func enqueueRegistration(
        _ request: EpochRegistrationRequestDTO,
        owner: UUID,
        epochID: UUID,
        routeID: UUID
    ) throws {
        guard request.protocolVersion == 2, request.epochID == epochID, request.deviceID == owner else {
            throw MeteringEpochDeliveryError.malformedRequest
        }
        let now = clock.now
        try store.transaction(expectedOwner: owner) { state in
            guard let route = state.routes[routeID],
                  let epoch = state.epochs[epochID],
                  route.ownerChildDeviceID == owner,
                  route.epochID == epochID,
                  request.usageDate == route.usageDate,
                  request.usageDate == epoch.usageDate
            else { throw MeteringEpochDeliveryError.malformedRequest }
            let workID = UUID()
            state.registrationWork[workID] = EpochRegistrationWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: request,
                claim: nil,
                retry: pendingRetry(at: now),
                createdAt: now
            )
        }
    }

    func enqueueActivation(
        _ request: EpochActivationRequestDTO,
        owner: UUID,
        epochID: UUID,
        routeID: UUID
    ) throws {
        guard request.protocolVersion == 2, request.deviceID == owner, request.routeID == routeID else {
            throw MeteringEpochDeliveryError.malformedRequest
        }
        let now = clock.now
        try store.transaction(expectedOwner: owner) { state in
            let workID = UUID()
            state.activationWork[workID] = EpochActivationWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: request,
                claim: nil,
                retry: pendingRetry(at: now),
                createdAt: now
            )
        }
    }

    func fetchChildState(owner: UUID) async throws -> ChildStateResponse {
        let request = MeteringEpochRequests.childState(baseURL: baseURL, ownerChildDeviceID: owner)
        let (data, response) = try await transport.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, 200..<300 ~= status else {
            throw MeteringEpochDeliveryError.unexpectedHTTPStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)
    }

    func drain(owner: UUID, importLegacyWork: Bool = true) async {
        if importLegacyWork, await self.importLegacyWork(owner: owner) {
            return
        }

        while let claimed = claimFirstDispatchable(owner: owner) {
            switch claimed {
            case let .registration(work, claim):
                await deliverRegistration(work: work, owner: owner, claim: claim)
            case let .activation(work, claim):
                await deliverActivation(work: work, owner: owner, claim: claim)
            case let .sample(work, claim):
                await deliverSample(work: work, owner: owner, claim: claim)
            }
        }
    }

    static func sampleDisposition(data: Data, statusCode: Int) -> EpochSampleHTTPDisposition {
        if (429 == statusCode) || (500...599).contains(statusCode) {
            return .retry(code: errorCode(data: data) ?? "http_\(statusCode)")
        }

        if 200..<300 ~= statusCode || statusCode == 409 {
            if statusCode == 409, errorCode(data: data) == "duplicate" {
                return .acceptedDuplicate
            }
            if let snapshot = decodeSnapshot(data) {
                if let warning = snapshot.warning {
                    return .terminal(code: warning, snapshot: snapshot)
                }
                if !snapshot.counted {
                    return .terminal(code: "not_counted", snapshot: snapshot)
                }
                return .accepted(snapshot)
            }
            if let code = errorCode(data: data) {
                return .terminal(code: code, snapshot: nil)
            }
            return statusCode == 409
                ? .terminal(code: "malformed_response", snapshot: nil)
                : .terminal(code: "malformed_response", snapshot: nil)
        }

        let snapshot = decodeSnapshot(data)
        if let code = errorCode(data: data) {
            return .terminal(code: code, snapshot: snapshot)
        }
        return .terminal(code: "http_\(statusCode)", snapshot: snapshot)
    }

    static func registrationDisposition(data: Data, statusCode: Int) -> EpochRegistrationHTTPDisposition {
        if (429 == statusCode) || (500...599).contains(statusCode) {
            return .retry(code: errorCode(data: data) ?? "http_\(statusCode)")
        }
        if 200..<300 ~= statusCode {
            guard let response = try? JSONDecoder.metering.decode(EpochRegistrationResponseDTO.self, from: data) else {
                return .terminal(code: "malformed_response")
            }
            guard response.meteringProtocolVersion == 2 else {
                return .terminal(code: "protocol_mismatch")
            }
            guard response.epochStatus == .active else {
                return .terminal(code: response.epochStatus == nil ? "missing_epoch_status" : "epoch_not_active")
            }
            return .registered(response)
        }
        if statusCode == 409, errorCode(data: data) == "authoritative_base_mismatch",
           let conflict = try? JSONDecoder.metering.decode(EpochRegistrationConflictDTO.self, from: data) {
            return .authoritativeBaseMismatch(conflict)
        }
        return .terminal(code: errorCode(data: data) ?? "http_\(statusCode)")
    }

    static func activationDisposition(data: Data, statusCode: Int) -> EpochActivationHTTPDisposition {
        if (429 == statusCode) || (500...599).contains(statusCode) {
            return .retry(code: errorCode(data: data) ?? "http_\(statusCode)")
        }
        if 200..<300 ~= statusCode {
            guard let response = try? JSONDecoder.metering.decode(EpochActivationResponseDTO.self, from: data) else {
                return .terminal(code: "malformed_response")
            }
            guard response.meteringProtocolVersion == 2 else {
                return .terminal(code: "protocol_mismatch")
            }
            guard response.epochStatus == .active else {
                return .terminal(code: "epoch_not_active")
            }
            guard response.status == .activated || response.status == .alreadyActivated else {
                return .terminal(code: "activation_not_acknowledged")
            }
            return .acknowledged(response)
        }
        return .terminal(code: errorCode(data: data) ?? "http_\(statusCode)")
    }

    private func claimFirstDispatchable(owner: UUID) -> MeteringClaimedNetworkWork? {
        guard store.isCurrentOwner(owner) else { return nil }
        return try? store.claimFirstNetworkWork(owner: owner, now: clock.now) { state, item in
            switch item.kind {
            case .registration:
                guard let registration = state.registrationWork.values.first(where: { $0.workID == item.workID }),
                      !isSuppressedCandidate(registration.epochID, state: state)
                else { return false }
                return true
            case .sample:
                guard let sample = state.sampleWork.values.first(where: { $0.workID == item.workID }),
                      !isSuppressedCandidate(sample.epochID, state: state),
                      isSampleDispatchable(sample, owner: owner, state: state)
                else { return false }
                return true
            case .activation:
                guard let activation = state.activationWork.values.first(where: { $0.workID == item.workID }),
                      !isSuppressedCandidate(activation.epochID, state: state),
                      let route = state.routes[activation.routeID],
                      route.ownerChildDeviceID == owner,
                      route.epochID == activation.epochID,
                      route.lifecycle == .active,
                      let epoch = state.epochs[activation.epochID],
                      epoch.childDeviceID == owner,
                      epoch.status == .active
                else { return false }
                let matchingRegistrations = state.registrationWork.values.filter {
                    $0.ownerChildDeviceID == owner
                        && $0.epochID == activation.epochID
                        && $0.routeID == activation.routeID
                }
                guard matchingRegistrations.contains(where: { $0.retry.terminal == .succeeded }) else { return false }
                guard state.installWork.values.contains(where: {
                    $0.ownerChildDeviceID == owner
                        && $0.routeID == activation.routeID
                        && isActivationReady($0.phase)
                }) else { return false }
                return true
            case .install:
                return false
            case .identityCleanup, .rollover, .shield:
                return false
            }
        }
    }

    private func importLegacyWork(owner: UUID) async -> Bool {
        let entries = EarnedSampleReporter.legacyRetryEntries(suiteName: legacySuiteName)
            .filter { $0.deviceID == owner }
        guard !entries.isEmpty else { return false }

        let imported = entries.compactMap { entry -> (EarnedSampleReporter.RetryEntry, EpochSampleRequestDTO)? in
            guard let request = EarnedSampleReporter.makeEpochSampleRequest(from: entry) else { return nil }
            return (entry, request)
        }
        guard !imported.isEmpty else { return false }

        do {
            try store.transaction(expectedOwner: owner) { state in
                for (_, request) in imported {
                    guard !state.sampleWork.values.contains(where: {
                        $0.ownerChildDeviceID == owner && $0.request.clientSampleID == request.clientSampleID
                    }) else { continue }
                    let workID = UUID()
                    state.sampleWork[workID] = EpochSampleWork(
                        workID: workID,
                        ownerChildDeviceID: owner,
                        epochID: nil,
                        routeID: nil,
                        request: request,
                        authorization: .legacyDeliverable,
                        claim: nil,
                        retry: pendingRetry(at: clock.now),
                        createdAt: clock.now
                    )
                }
            }
#if DEBUG
            if let debugAfterLegacyImportReadback {
                debugAfterLegacyImportReadback()
                return true
            }
#endif
            for (entry, _) in imported {
                EarnedSampleReporter.removeRetryEntry(entry, suiteName: legacySuiteName)
            }
        } catch {
            // The legacy payload remains the recovery source until the root
            // transaction has completed its verified readback.
        }
        return false
    }

    private func deliverRegistration(work: EpochRegistrationWork, owner: UUID, claim: MeteringNetworkClaim) async {
        let workID = work.workID
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.registration(baseURL: baseURL, ownerChildDeviceID: owner, body: work.request)
        } catch {
            await terminalizeRegistration(workID: workID, owner: owner, claim: claim, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            let disposition = Self.registrationDisposition(data: data, statusCode: httpStatus(response))
            switch disposition {
            case let .registered(response):
                guard response.epochID == work.epochID else {
                    await terminalizeRegistration(workID: workID, owner: owner, claim: claim, code: "epoch_mismatch")
                    return
                }
                guard snapshotMatches(response.snapshot, owner: owner, usageDate: work.request.usageDate) else {
                    await terminalizeRegistration(workID: workID, owner: owner, claim: claim, code: "snapshot_mismatch")
                    return
                }
                await recordRegistrationSuccess(workID: workID, owner: owner, claim: claim, response: response)
            case let .authoritativeBaseMismatch(conflict):
                await recordAuthoritativeBaseMismatch(workID: workID, owner: owner, claim: claim, conflict: conflict)
            case let .terminal(code):
                await terminalizeRegistration(workID: workID, owner: owner, claim: claim, code: code)
            case let .retry(code):
                await retryRegistration(workID: workID, owner: owner, claim: claim, code: code)
            }
        } catch {
            await retryRegistration(workID: workID, owner: owner, claim: claim, code: "network_error")
        }
    }

    private func deliverActivation(work: EpochActivationWork, owner: UUID, claim: MeteringNetworkClaim) async {
        let workID = work.workID
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.activation(
                baseURL: baseURL,
                ownerChildDeviceID: owner,
                epochID: work.epochID,
                body: work.request
            )
        } catch {
            await terminalizeActivation(workID: workID, owner: owner, claim: claim, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            switch Self.activationDisposition(data: data, statusCode: httpStatus(response)) {
            case let .acknowledged(response):
                guard response.epochID == work.epochID else {
                    await terminalizeActivation(workID: workID, owner: owner, claim: claim, code: "epoch_mismatch")
                    return
                }
                guard let usageDate = (try? store.read())?.epochs[work.epochID]?.usageDate,
                      snapshotMatches(response.snapshot, owner: owner, usageDate: usageDate) else {
                    await terminalizeActivation(workID: workID, owner: owner, claim: claim, code: "snapshot_mismatch")
                    return
                }
                await terminalizeActivation(workID: workID, owner: owner, claim: claim, code: nil, terminal: .succeeded, snapshot: response.snapshot)
            case let .terminal(code):
                await terminalizeActivation(workID: workID, owner: owner, claim: claim, code: code)
            case let .retry(code):
                await retryActivation(workID: workID, owner: owner, claim: claim, code: code)
            }
        } catch {
            await retryActivation(workID: workID, owner: owner, claim: claim, code: "network_error")
        }
    }

    private func deliverSample(work: EpochSampleWork, owner: UUID, claim: MeteringNetworkClaim) async {
        let workID = work.workID
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.sample(baseURL: baseURL, ownerChildDeviceID: owner, body: work.request)
        } catch {
            await terminalizeSample(workID: workID, owner: owner, claim: claim, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            switch Self.sampleDisposition(data: data, statusCode: httpStatus(response)) {
            case let .accepted(snapshot):
                guard snapshotMatches(snapshot, owner: owner, usageDate: work.request.usageDate) else {
                    await terminalizeSample(workID: workID, owner: owner, claim: claim, code: "snapshot_mismatch")
                    return
                }
                await terminalizeSample(workID: workID, owner: owner, claim: claim, code: nil, terminal: .succeeded, snapshot: snapshot)
            case .acceptedDuplicate:
                await terminalizeSample(workID: workID, owner: owner, claim: claim, code: nil, terminal: .succeeded)
            case let .terminal(code, snapshot):
                if let snapshot,
                   !snapshotMatches(snapshot, owner: owner, usageDate: work.request.usageDate) {
                    await terminalizeSample(workID: workID, owner: owner, claim: claim, code: "snapshot_mismatch")
                    return
                }
                await terminalizeSample(workID: workID, owner: owner, claim: claim, code: code, snapshot: snapshot)
            case let .retry(code):
                await retrySample(workID: workID, owner: owner, claim: claim, code: code)
            }
        } catch {
            await retrySample(workID: workID, owner: owner, claim: claim, code: "network_error")
        }
    }


    private func recordRegistrationSuccess(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        response: EpochRegistrationResponseDTO
    ) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token
            else { return }
            if supersedeStaleRegistrationWork(&state, key: key, work: &work, owner: owner, claim: claim) {
                return
            }
            guard let route = state.routes[work.routeID],
                  route.ownerChildDeviceID == owner,
                  route.epochID == work.epochID,
                  let epoch = state.epochs[work.epochID],
                  epoch.childDeviceID == owner,
                  work.request.usageDate == route.usageDate,
                  work.request.usageDate == epoch.usageDate,
                  epoch.status == .active,
                  epoch.authoritativeBaseConflict == nil,
                  (route.lifecycle == .planned || route.lifecycle == .active),
                  response.epochID == work.epochID,
                  snapshotMatches(response.snapshot, owner: owner, usageDate: route.usageDate)
            else { return }
            work.retry = completedRetry(from: work.retry, code: nil, terminal: .succeeded)
            work.claim = nil
            state.registrationWork[key] = work
            state.epochs[work.epochID]?.registeredAt = clock.now
            for (installKey, var installWork) in state.installWork where
                installWork.ownerChildDeviceID == owner
                    && installWork.routeID == route.routeID
                    && installWork.authorization == .registrationRequired
                    && installWork.retry.terminal == .pending {
                installWork.authorization = .registered
                state.installWork[installKey] = installWork
            }
            var ratchet = state.ratchets[owner] ?? MeteringOwnerRatchet(
                ownerChildDeviceID: owner,
                advertisedVersion: 1,
                localSelection: .v1,
                registeredV2At: nil,
                dualActiveAt: nil,
                activatedV2At: nil
            )
            let selection = ratchet.localSelection
            ratchet.registeredV2At = clock.now
            ratchet.localSelection = selection
            state.ratchets[owner] = ratchet
        }
    }

    private func recordAuthoritativeBaseMismatch(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        conflict: EpochRegistrationConflictDTO
    ) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token
            else { return }
            if supersedeStaleRegistrationWork(&state, key: key, work: &work, owner: owner, claim: claim) {
                return
            }
            guard let route = state.routes[work.routeID],
                  route.ownerChildDeviceID == owner,
                  route.epochID == work.epochID,
                  (route.lifecycle == .planned || route.lifecycle == .active),
                  var epoch = state.epochs[work.epochID],
                  epoch.childDeviceID == owner,
                  epoch.authoritativeBaseConflict == nil,
                  conflict.authoritativeSnapshot.childDeviceID == owner,
                  conflict.authoritativeSnapshot.usageDate == route.usageDate,
                  conflict.authoritativeSnapshot.usageDate == epoch.usageDate
            else { return }
            epoch.authoritativeBaseConflict = conflict
            state.epochs[work.epochID] = epoch
            work.retry = completedRetry(from: work.retry, code: "authoritative_base_mismatch", terminal: .superseded)
            work.claim = nil
            state.registrationWork[key] = work
        }
    }

    private func terminalizeRegistration(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String,
        terminal: MeteringWorkTerminal = .rejected
    ) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token
            else { return }
            if supersedeStaleRegistrationWork(&state, key: key, work: &work, owner: owner, claim: claim) {
                return
            }
            guard let route = state.routes[work.routeID],
                  route.ownerChildDeviceID == owner,
                  (route.lifecycle == .planned || route.lifecycle == .active),
                  route.epochID == work.epochID,
                  let epoch = state.epochs[work.epochID],
                  epoch.childDeviceID == owner,
                  epoch.authoritativeBaseConflict == nil,
                  work.request.usageDate == route.usageDate,
                  work.request.usageDate == epoch.usageDate
            else { return }
            work.retry = completedRetry(from: work.retry, code: code, terminal: terminal)
            work.claim = nil
            state.registrationWork[key] = work
        }
    }

    private func retryRegistration(workID: UUID, owner: UUID, claim: MeteringNetworkClaim, code: String) async {
        updateRegistration(workID: workID, owner: owner, claim: claim, code: code, terminal: .pending)
    }

    private func updateRegistration(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String,
        terminal: MeteringWorkTerminal
    ) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token
            else { return }
            if supersedeStaleRegistrationWork(&state, key: key, work: &work, owner: owner, claim: claim) {
                return
            }
            guard let route = state.routes[work.routeID],
                  route.ownerChildDeviceID == owner,
                  (route.lifecycle == .planned || route.lifecycle == .active),
                  route.epochID == work.epochID,
                  let epoch = state.epochs[work.epochID],
                  epoch.childDeviceID == owner,
                  epoch.authoritativeBaseConflict == nil,
                  work.request.usageDate == route.usageDate,
                  work.request.usageDate == epoch.usageDate
            else { return }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code, now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
            work.claim = nil
            state.registrationWork[key] = work
        }
    }

    func supersedeStaleRegistrationWork(
        _ state: inout DeviceEpochStoreState,
        key: UUID,
        work: inout EpochRegistrationWork,
        owner: UUID,
        claim: MeteringNetworkClaim
    ) -> Bool {
        guard work.ownerChildDeviceID == owner,
              work.claim?.token == claim.token
        else { return false }
        let routeIsCurrent = state.routes[work.routeID].map {
            $0.ownerChildDeviceID == owner
                && $0.epochID == work.epochID
                && ($0.lifecycle == .planned || $0.lifecycle == .active)
        } ?? false
        guard !routeIsCurrent else { return false }
        work.retry = completedRetry(from: work.retry, code: "route_superseded", terminal: .superseded)
        work.claim = nil
        state.registrationWork[key] = work
        return true
    }

    private func terminalizeActivation(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String?,
        terminal: MeteringWorkTerminal = .rejected,
        snapshot: DeviceDaySnapshotDTO? = nil
    ) async {
        updateActivation(workID: workID, owner: owner, claim: claim, code: code, terminal: terminal, snapshot: snapshot)
    }

    private func retryActivation(workID: UUID, owner: UUID, claim: MeteringNetworkClaim, code: String) async {
        updateActivation(workID: workID, owner: owner, claim: claim, code: code, terminal: .pending)
    }

    private func updateActivation(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String?,
        terminal: MeteringWorkTerminal,
        snapshot: DeviceDaySnapshotDTO? = nil
    ) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.activationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.activationWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token,
                  let epoch = state.epochs[work.epochID],
                  epoch.childDeviceID == owner,
                  epoch.status == .active,
                  epoch.authoritativeBaseConflict == nil,
                  let route = state.routes[work.routeID],
                  route.ownerChildDeviceID == owner,
                  route.lifecycle == .active,
                  route.epochID == work.epochID,
                  state.registrationWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.epochID == work.epochID
                          && $0.routeID == work.routeID
                          && $0.retry.terminal == .succeeded
                  }),
                  state.installWork.values.contains(where: {
                      $0.ownerChildDeviceID == owner
                          && $0.routeID == work.routeID
                          && isActivationReady($0.phase)
                  })
            else { return }
            if terminal == .succeeded {
                guard let snapshot, snapshotMatches(snapshot, owner: owner, usageDate: epoch.usageDate) else { return }
            }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code ?? "network_error", now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
            work.claim = nil
            state.activationWork[key] = work
        }
    }

    private func terminalizeSample(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String?,
        terminal: MeteringWorkTerminal = .rejected,
        snapshot: DeviceDaySnapshotDTO? = nil
    ) async {
        updateSample(workID: workID, owner: owner, claim: claim, code: code, terminal: terminal, snapshot: snapshot)
    }

    private func retrySample(workID: UUID, owner: UUID, claim: MeteringNetworkClaim, code: String) async {
        updateSample(workID: workID, owner: owner, claim: claim, code: code, terminal: .pending)
    }

    private func updateSample(
        workID: UUID,
        owner: UUID,
        claim: MeteringNetworkClaim,
        code: String?,
        terminal: MeteringWorkTerminal,
        snapshot: DeviceDaySnapshotDTO? = nil
    ) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.sampleWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.sampleWork[key],
                  work.ownerChildDeviceID == owner,
                  work.claim?.token == claim.token
            else { return }
            if let routeID = work.routeID {
                guard let route = state.routes[routeID],
                      route.ownerChildDeviceID == owner,
                      route.lifecycle == .active,
                      route.epochID == work.epochID,
                      let epochID = work.epochID,
                      let epoch = state.epochs[epochID],
                      epoch.childDeviceID == owner,
                      epoch.status == .active,
                      epoch.authoritativeBaseConflict == nil
                else { return }
            }
            if let snapshot {
                guard snapshotMatches(snapshot, owner: owner, usageDate: work.request.usageDate) else { return }
            }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code ?? "network_error", now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
            work.claim = nil
            state.sampleWork[key] = work
        }
    }

    private func pendingRetry(at date: Date) -> MeteringRetryState {
        MeteringRetryState(attemptCount: 0, nextAttemptAt: date, lastErrorCode: nil, terminal: .pending)
    }

    private func retryState(after prior: MeteringRetryState, code: String, now: Date) -> MeteringRetryState {
        let attempt = prior.attemptCount + 1
        let nextAttemptAt: Date
        if attempt < MeteringRetryPolicy.delays.count {
            let priorIndex = min(max(prior.attemptCount, 0), MeteringRetryPolicy.delays.count - 1)
            let origin = prior.nextAttemptAt.addingTimeInterval(-MeteringRetryPolicy.delays[priorIndex])
            nextAttemptAt = origin.addingTimeInterval(MeteringRetryPolicy.delays[attempt])
        } else {
            nextAttemptAt = now.addingTimeInterval(MeteringRetryPolicy.delays.last ?? 0)
        }
        return MeteringRetryState(
            attemptCount: attempt,
            nextAttemptAt: nextAttemptAt,
            lastErrorCode: code,
            terminal: .pending
        )
    }

    private func completedRetry(
        from prior: MeteringRetryState,
        code: String?,
        terminal: MeteringWorkTerminal
    ) -> MeteringRetryState {
        MeteringRetryState(
            attemptCount: prior.attemptCount,
            nextAttemptAt: prior.nextAttemptAt,
            lastErrorCode: code,
            terminal: terminal
        )
    }

    private func httpStatus(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private static func decodeSnapshot(_ data: Data) -> DeviceDaySnapshotDTO? {
        try? JSONDecoder.metering.decode(DeviceDaySnapshotDTO.self, from: data)
    }

    private static func errorCode(data: Data) -> String? {
        struct ErrorEnvelope: Decodable { let code: String }
        return try? JSONDecoder.metering.decode(ErrorEnvelope.self, from: data).code
    }

    private func isSuppressedCandidate(_ epochID: UUID?, state: DeviceEpochStoreState) -> Bool {
        guard let epochID else { return false }
        return state.epochs[epochID]?.authoritativeBaseConflict != nil
    }

    private func isSampleDispatchable(
        _ sample: EpochSampleWork,
        owner: UUID,
        state: DeviceEpochStoreState
    ) -> Bool {
        switch sample.authorization {
        case .waitingForRegistration:
            return false
        case .legacyDeliverable:
            return sample.ownerChildDeviceID == owner
                && sample.epochID == nil
                && sample.routeID == nil
                && sample.request.lane == .v1
        case .v2Deliverable:
            guard let routeID = sample.routeID,
                  let epochID = sample.epochID,
                  let route = state.routes[routeID],
                  let epoch = state.epochs[epochID]
            else { return false }
            return sample.ownerChildDeviceID == owner
                && route.ownerChildDeviceID == owner
                && route.epochID == epochID
                && route.lifecycle == .active
                && epoch.childDeviceID == owner
                && epoch.status == .active
                && epoch.authoritativeBaseConflict == nil
                && sample.request.lane == .v2
                && sample.request.epochID == epochID
                && sample.request.usageDate == route.usageDate
                && sample.request.usageDate == epoch.usageDate
                && sample.request.activityName == route.activityName
        }
    }

    private func isActivationReady(_ phase: ActivityInstallPhase) -> Bool {
        switch phase {
        case .verified, .dualActive, .active:
            return true
        case .pendingStart, .starting, .installed, .pendingStop, .stopped:
            return false
        }
    }

    private func snapshotMatches(_ snapshot: DeviceDaySnapshotDTO, owner: UUID, usageDate: String) -> Bool {
        snapshot.childDeviceID == owner && snapshot.usageDate == usageDate
    }
}

private extension JSONDecoder {
    static let metering: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
