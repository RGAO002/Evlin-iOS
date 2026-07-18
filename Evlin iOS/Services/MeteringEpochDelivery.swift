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
    private var simulateCrashAfterLegacyImportReadback: Bool

    init(
        baseURL: URL,
        store: DeviceEpochStore = .shared,
        transport: any MeteringHTTPTransport,
        clock: any MeteringClock = MeteringRuntimeClock.live(),
        legacySuiteName: String = "group.com.evlin.ios",
        simulateCrashAfterLegacyImportReadback: Bool = false
    ) {
        self.baseURL = baseURL
        self.store = store
        self.transport = transport
        self.clock = clock
        self.legacySuiteName = legacySuiteName
        self.simulateCrashAfterLegacyImportReadback = simulateCrashAfterLegacyImportReadback
    }

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
            let workID = UUID()
            state.registrationWork[workID] = EpochRegistrationWork(
                workID: workID,
                ownerChildDeviceID: owner,
                epochID: epochID,
                routeID: routeID,
                request: request,
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

    func drain(owner: UUID) async {
        if await importLegacyWork(owner: owner) {
            return
        }

        while let next = nextDispatchable(owner: owner) {
            switch next.kind {
            case .registration:
                await deliverRegistration(workID: next.workID, owner: owner)
            case .activation:
                await deliverActivation(workID: next.workID, owner: owner)
            case .sample:
                await deliverSample(workID: next.workID, owner: owner)
            case .identityCleanup, .rollover, .install, .shield:
                return
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

        if let code = errorCode(data: data) {
            return .terminal(code: code, snapshot: decodeSnapshot(data))
        }
        return .terminal(code: "http_\(statusCode)", snapshot: nil)
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

    private func nextDispatchable(owner: UUID) -> MeteringDueWork? {
        guard store.isCurrentOwner(owner),
              let state = try? store.read(),
              state.ownerChildDeviceID == owner else { return nil }
        let due = state.dueWork(now: clock.now)
        for item in due {
            switch item.kind {
            case .registration:
                return item
            case .sample:
                guard let sample = state.sampleWork.values.first(where: { $0.workID == item.workID }),
                      !isSuppressedCandidate(sample.epochID, state: state)
                else { continue }
                return item
            case .activation:
                guard let activation = state.activationWork.values.first(where: { $0.workID == item.workID }),
                      !isSuppressedCandidate(activation.epochID, state: state)
                else { continue }
                let matchingRegistrations = state.registrationWork.values.filter {
                    $0.ownerChildDeviceID == owner
                        && $0.epochID == activation.epochID
                }
                guard matchingRegistrations.contains(where: { $0.retry.terminal == .succeeded }) else { continue }
                guard state.installWork.values.contains(where: {
                    $0.ownerChildDeviceID == owner
                        && $0.routeID == activation.routeID
                        && isVerifiedOrLater($0.phase)
                }) else { continue }
                return item
            case .identityCleanup, .rollover, .install, .shield:
                continue
            }
        }
        return nil
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
                        retry: pendingRetry(at: clock.now),
                        createdAt: clock.now
                    )
                }
            }
            if simulateCrashAfterLegacyImportReadback {
                simulateCrashAfterLegacyImportReadback = false
                return true
            }
            for (entry, _) in imported {
                EarnedSampleReporter.removeRetryEntry(entry, suiteName: legacySuiteName)
            }
        } catch {
            // The legacy payload remains the recovery source until the root
            // transaction has completed its verified readback.
        }
        return false
    }

    private func deliverRegistration(workID: UUID, owner: UUID) async {
        guard let work = registrationWork(withID: workID, owner: owner) else { return }
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.registration(baseURL: baseURL, ownerChildDeviceID: owner, body: work.request)
        } catch {
            await terminalizeRegistration(workID: workID, owner: owner, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            let disposition = Self.registrationDisposition(data: data, statusCode: httpStatus(response))
            switch disposition {
            case let .registered(response):
                guard response.epochID == work.epochID else {
                    await terminalizeRegistration(workID: workID, owner: owner, code: "epoch_mismatch")
                    return
                }
                await recordRegistrationSuccess(workID: workID, owner: owner, response: response)
            case let .authoritativeBaseMismatch(conflict):
                await recordAuthoritativeBaseMismatch(workID: workID, owner: owner, conflict: conflict)
            case let .terminal(code):
                await terminalizeRegistration(workID: workID, owner: owner, code: code)
            case let .retry(code):
                await retryRegistration(workID: workID, owner: owner, code: code)
            }
        } catch {
            await retryRegistration(workID: workID, owner: owner, code: "network_error")
        }
    }

    private func deliverActivation(workID: UUID, owner: UUID) async {
        guard let work = activationWork(withID: workID, owner: owner) else { return }
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.activation(
                baseURL: baseURL,
                ownerChildDeviceID: owner,
                epochID: work.epochID,
                body: work.request
            )
        } catch {
            await terminalizeActivation(workID: workID, owner: owner, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            switch Self.activationDisposition(data: data, statusCode: httpStatus(response)) {
            case let .acknowledged(response):
                guard response.epochID == work.epochID else {
                    await terminalizeActivation(workID: workID, owner: owner, code: "epoch_mismatch")
                    return
                }
                await terminalizeActivation(workID: workID, owner: owner, code: nil, terminal: .succeeded)
            case let .terminal(code):
                await terminalizeActivation(workID: workID, owner: owner, code: code)
            case let .retry(code):
                await retryActivation(workID: workID, owner: owner, code: code)
            }
        } catch {
            await retryActivation(workID: workID, owner: owner, code: "network_error")
        }
    }

    private func deliverSample(workID: UUID, owner: UUID) async {
        guard let work = sampleWork(withID: workID, owner: owner) else { return }
        let request: URLRequest
        do {
            request = try MeteringEpochRequests.sample(baseURL: baseURL, ownerChildDeviceID: owner, body: work.request)
        } catch {
            await terminalizeSample(workID: workID, owner: owner, code: "malformed_request")
            return
        }

        do {
            let (data, response) = try await transport.data(for: request)
            switch Self.sampleDisposition(data: data, statusCode: httpStatus(response)) {
            case .accepted:
                await terminalizeSample(workID: workID, owner: owner, code: nil, terminal: .succeeded)
            case .acceptedDuplicate:
                await terminalizeSample(workID: workID, owner: owner, code: nil, terminal: .succeeded)
            case let .terminal(code, _):
                await terminalizeSample(workID: workID, owner: owner, code: code)
            case let .retry(code):
                await retrySample(workID: workID, owner: owner, code: code)
            }
        } catch {
            await retrySample(workID: workID, owner: owner, code: "network_error")
        }
    }

    private func registrationWork(withID workID: UUID, owner: UUID) -> EpochRegistrationWork? {
        guard let state = try? store.read(), state.ownerChildDeviceID == owner else { return nil }
        return state.registrationWork.values.first { $0.workID == workID }
    }

    private func activationWork(withID workID: UUID, owner: UUID) -> EpochActivationWork? {
        guard let state = try? store.read(), state.ownerChildDeviceID == owner else { return nil }
        return state.activationWork.values.first { $0.workID == workID }
    }

    private func sampleWork(withID workID: UUID, owner: UUID) -> EpochSampleWork? {
        guard let state = try? store.read(), state.ownerChildDeviceID == owner else { return nil }
        return state.sampleWork.values.first { $0.workID == workID }
    }

    private func recordRegistrationSuccess(workID: UUID, owner: UUID, response: EpochRegistrationResponseDTO) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  let route = state.routes[work.routeID],
                  route.epochID == work.epochID,
                  let epoch = state.epochs[work.epochID],
                  epoch.status == .active,
                  response.epochID == work.epochID
            else { return }
            work.retry = completedRetry(from: work.retry, code: nil, terminal: .succeeded)
            state.registrationWork[key] = work
            state.epochs[work.epochID]?.registeredAt = clock.now
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
        conflict: EpochRegistrationConflictDTO
    ) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  let route = state.routes[work.routeID],
                  route.epochID == work.epochID,
                  var epoch = state.epochs[work.epochID]
            else { return }
            epoch.authoritativeBaseConflict = conflict
            state.epochs[work.epochID] = epoch
            work.retry = completedRetry(from: work.retry, code: "authoritative_base_mismatch", terminal: .superseded)
            state.registrationWork[key] = work
        }
    }

    private func terminalizeRegistration(
        workID: UUID,
        owner: UUID,
        code: String,
        terminal: MeteringWorkTerminal = .rejected
    ) async {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  state.routes[work.routeID]?.epochID == work.epochID
            else { return }
            work.retry = completedRetry(from: work.retry, code: code, terminal: terminal)
            state.registrationWork[key] = work
        }
    }

    private func retryRegistration(workID: UUID, owner: UUID, code: String) async {
        updateRegistration(workID: workID, owner: owner, code: code, terminal: .pending)
    }

    private func updateRegistration(workID: UUID, owner: UUID, code: String, terminal: MeteringWorkTerminal) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.registrationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.registrationWork[key],
                  work.ownerChildDeviceID == owner,
                  state.routes[work.routeID]?.epochID == work.epochID
            else { return }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code, now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
            state.registrationWork[key] = work
        }
    }

    private func terminalizeActivation(
        workID: UUID,
        owner: UUID,
        code: String?,
        terminal: MeteringWorkTerminal = .rejected
    ) async {
        updateActivation(workID: workID, owner: owner, code: code, terminal: terminal)
    }

    private func retryActivation(workID: UUID, owner: UUID, code: String) async {
        updateActivation(workID: workID, owner: owner, code: code, terminal: .pending)
    }

    private func updateActivation(workID: UUID, owner: UUID, code: String?, terminal: MeteringWorkTerminal) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.activationWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.activationWork[key],
                  work.ownerChildDeviceID == owner,
                  state.routes[work.routeID]?.epochID == work.epochID
            else { return }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code ?? "network_error", now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
            state.activationWork[key] = work
        }
    }

    private func terminalizeSample(
        workID: UUID,
        owner: UUID,
        code: String?,
        terminal: MeteringWorkTerminal = .rejected
    ) async {
        updateSample(workID: workID, owner: owner, code: code, terminal: terminal)
    }

    private func retrySample(workID: UUID, owner: UUID, code: String) async {
        updateSample(workID: workID, owner: owner, code: code, terminal: .pending)
    }

    private func updateSample(workID: UUID, owner: UUID, code: String?, terminal: MeteringWorkTerminal) {
        try? store.transaction(expectedOwner: owner) { state in
            guard let key = state.sampleWork.first(where: { $0.value.workID == workID })?.key,
                  var work = state.sampleWork[key],
                  work.ownerChildDeviceID == owner
            else { return }
            if let routeID = work.routeID, state.routes[routeID]?.epochID != work.epochID { return }
            work.retry = terminal == .pending
                ? retryState(after: work.retry, code: code ?? "network_error", now: clock.now)
                : completedRetry(from: work.retry, code: code, terminal: terminal)
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

    private func isVerifiedOrLater(_ phase: ActivityInstallPhase) -> Bool {
        switch phase {
        case .verified, .dualActive, .active, .pendingStop, .stopped:
            return true
        case .pendingStart, .starting, .installed:
            return false
        }
    }
}

private extension JSONDecoder {
    static let metering: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
