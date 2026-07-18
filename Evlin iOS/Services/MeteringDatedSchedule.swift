import DeviceActivity
import FamilyControls
import Foundation

nonisolated enum MeteringDatedScheduleError: Error, Equatable {
    case invalidUsageDate(String)
}

nonisolated struct MeteringHorizonRequest: Equatable, Sendable {
    let ownerChildDeviceID: UUID
    let today: String
    let generationKey: MeteringGenerationKey
    let persistedSelectionBytes: Data
    let poolMinutes: Int
    let deviceCapMinutes: Int
    let authoritativeBaseAcceptedMinutes: Int
    let now: Date
}

nonisolated struct MeteringHorizonPlan: Equatable, Sendable {
    let generationID: UUID
    let routeIDsByUsageDate: [String: UUID]
}

nonisolated enum MeteringHorizonPlanningError: Error, Equatable {
    case ownerDoesNotMatchGeneration
    case selectionDigestMismatch
    case invalidTimezone(String)
    case negativeAuthoritativeBase
}

nonisolated enum MeteringHorizonPlanner {
    static let dateCount = 8

    static func requiredUsageDates(
        today: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> [String] {
        let policyCalendar = configuredCalendar(calendar, timeZone: timeZone)
        let start = try canonicalMidnight(
            usageDate: today,
            calendar: policyCalendar,
            timeZone: timeZone
        )
        return try (0..<dateCount).map { offset in
            guard let date = policyCalendar.date(byAdding: .day, value: offset, to: start) else {
                throw MeteringDatedScheduleError.invalidUsageDate(today)
            }
            return formattedUsageDate(date, calendar: policyCalendar)
        }
    }
}

nonisolated enum MeteringDatedSchedule {
    static let earnedBucketMinutes = 5
    static let guardEventCount = 48

    static func thresholds(poolMinutes: Int, capMinutes: Int) -> [Int] {
        let ceiling = min(poolMinutes, capMinutes)
        guard ceiling > 0 else { return [] }

        let minimumStep = ceiling / guardEventCount
            + (ceiling % guardEventCount == 0 ? 0 : 1)
        let step = max(
            earnedBucketMinutes,
            ((minimumStep + earnedBucketMinutes - 1) / earnedBucketMinutes) * earnedBucketMinutes
        )
        var result = stride(
            from: step,
            through: ceiling,
            by: step
        ).map { $0 }
        if result.last != ceiling {
            result.append(ceiling)
        }
        return result
    }

    static func remainingPolicy(
        poolMinutes: Int,
        capMinutes: Int,
        offsetMinutes: Int
    ) -> (poolMinutes: Int, capMinutes: Int)? {
        let remainingCeiling = min(poolMinutes, capMinutes) - max(0, offsetMinutes)
        guard remainingCeiling > 0 else { return nil }
        return (remainingCeiling, remainingCeiling)
    }

    static func datedSchedule(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule {
        let policyCalendar = configuredCalendar(calendar, timeZone: timeZone)
        let start = try canonicalMidnight(
            usageDate: usageDate,
            calendar: policyCalendar,
            timeZone: timeZone
        )
        guard let end = policyCalendar.date(byAdding: .day, value: 1, to: start) else {
            throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
        }
        return DeviceActivitySchedule(
            intervalStart: calendarComponents(for: start, calendar: policyCalendar, timeZone: timeZone),
            intervalEnd: calendarComponents(for: end, calendar: policyCalendar, timeZone: timeZone),
            repeats: false
        )
    }

    static func makeEvent(
        selection: FamilyActivitySelection,
        thresholdMinutes: Int
    ) -> DeviceActivityEvent {
        precondition(thresholdMinutes > 0, "Metering event threshold must be positive")
        return DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: thresholdMinutes),
            includesPastActivity: false
        )
    }
}

extension DeviceEpochStore {
    @discardableResult
    func reconcileMeteringHorizon(_ request: MeteringHorizonRequest) throws -> MeteringHorizonPlan {
        guard request.ownerChildDeviceID == request.generationKey.childDeviceID else {
            throw MeteringHorizonPlanningError.ownerDoesNotMatchGeneration
        }
        guard request.authoritativeBaseAcceptedMinutes >= 0 else {
            throw MeteringHorizonPlanningError.negativeAuthoritativeBase
        }
        guard request.generationKey.measurementSelectionDigest == MeteringEpochContract.selectionDigest(
            persistedBytes: request.persistedSelectionBytes
        ) else {
            throw MeteringHorizonPlanningError.selectionDigestMismatch
        }
        guard let timeZone = TimeZone(identifier: request.generationKey.canonicalTimezone) else {
            throw MeteringHorizonPlanningError.invalidTimezone(request.generationKey.canonicalTimezone)
        }
        let usageDates = try MeteringHorizonPlanner.requiredUsageDates(
            today: request.today,
            timeZone: timeZone
        )

        return try transaction(expectedOwner: request.ownerChildDeviceID) { state in
            let matchesRequest: (MeteringPolicyGeneration) -> Bool = {
                guard $0.retiredAt == nil else { return false }
                return MeteringGenerationKey(
                    protocolVersion: $0.protocolVersion,
                    childDeviceID: $0.childDeviceID,
                    canonicalTimezone: $0.canonicalTimezone,
                    policyRevision: $0.policyRevision,
                    measurementSelectionDigest: $0.measurementSelectionDigest,
                    enforcementSetID: $0.enforcementSetID
                ) == request.generationKey
            }
            let activeMatch = state.activeGenerationID
                .flatMap { state.generations[$0] }
                .flatMap { matchesRequest($0) ? $0 : nil }
            let deterministicMatch = state.generations.values
                .filter(matchesRequest)
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.generationID.uuidString.lowercased()
                        < $1.generationID.uuidString.lowercased()
                }
                .first
            let generation = activeMatch ?? deterministicMatch ?? MeteringPolicyGeneration(
                generationID: UUID(),
                protocolVersion: request.generationKey.protocolVersion,
                childDeviceID: request.generationKey.childDeviceID,
                canonicalTimezone: request.generationKey.canonicalTimezone,
                policyRevision: request.generationKey.policyRevision,
                measurementSelectionDigest: request.generationKey.measurementSelectionDigest,
                enforcementSetID: request.generationKey.enforcementSetID,
                measurementSelectionBytes: request.persistedSelectionBytes,
                createdAt: request.now,
                retiredAt: nil
            )
            state.generations[generation.generationID] = generation
            if state.activeRouteID == nil {
                state.activeGenerationID = generation.generationID
            }

            var routeIDsByUsageDate: [String: UUID] = [:]
            for usageDate in usageDates {
                if let existing = state.routes.values.first(where: {
                    $0.generationID == generation.generationID && $0.usageDate == usageDate
                }) {
                    routeIDsByUsageDate[usageDate] = existing.routeID
                    continue
                }

                let routeID = UUID()
                let epochID = UUID()
                let isToday = usageDate == request.today
                state.epochs[epochID] = DeviceDailyEpoch(
                    epochID: epochID,
                    protocolVersion: generation.protocolVersion,
                    childDeviceID: request.ownerChildDeviceID,
                    usageDate: usageDate,
                    canonicalTimezone: generation.canonicalTimezone,
                    policyRevision: generation.policyRevision,
                    measurementSelectionDigest: generation.measurementSelectionDigest,
                    enforcementSetID: generation.enforcementSetID,
                    startedAt: request.now,
                    registeredAt: nil,
                    baseAcceptedMinutes: isToday ? request.authoritativeBaseAcceptedMinutes : 0,
                    baseSource: .childState200,
                    lastRawThresholdMinutes: 0,
                    excludedWhilePausedMinutes: 0,
                    status: .active,
                    resumeBoundaryPending: false,
                    retiredAt: nil,
                    retireReason: nil,
                    exhaustedAt: nil,
                    baseCorrectionState: .available
                )
                let thresholds: [Int]
                if isToday,
                   let remaining = MeteringDatedSchedule.remainingPolicy(
                       poolMinutes: request.poolMinutes,
                       capMinutes: request.deviceCapMinutes,
                       offsetMinutes: request.authoritativeBaseAcceptedMinutes
                   ) {
                    thresholds = MeteringDatedSchedule.thresholds(
                        poolMinutes: remaining.poolMinutes,
                        capMinutes: remaining.capMinutes
                    )
                } else if isToday {
                    thresholds = []
                } else {
                    thresholds = MeteringDatedSchedule.thresholds(
                        poolMinutes: request.poolMinutes,
                        capMinutes: request.deviceCapMinutes
                    )
                }
                state.routes[routeID] = MeteringCallbackRoute(
                    routeID: routeID,
                    activityName: MeteringRouteNamespace.activityName(routeID: routeID),
                    namespace: MeteringRouteNamespace.prefix,
                    generationID: generation.generationID,
                    generationKey: request.generationKey,
                    ownerChildDeviceID: request.ownerChildDeviceID,
                    usageDate: usageDate,
                    epochID: epochID,
                    plannedSchedule: DatedSchedulePlan(
                        usageDate: usageDate,
                        timezoneIdentifier: generation.canonicalTimezone,
                        calendarIdentifier: "gregorian"
                    ),
                    installedSchedule: nil,
                    plannedEvents: thresholds.map { thresholdMinutes in
                        MeteringEventPlan(
                            eventName: MeteringRouteNamespace.eventName(
                                routeID: routeID,
                                thresholdMinutes: thresholdMinutes
                            ),
                            thresholdMinutes: thresholdMinutes
                        )
                    },
                    installedEvents: nil,
                    lifecycle: .planned,
                    createdAt: request.now
                )
                let installWorkID = UUID()
                state.installWork[installWorkID] = ActivityInstallWork(
                    workID: installWorkID,
                    ownerChildDeviceID: request.ownerChildDeviceID,
                    routeID: routeID,
                    authorization: isToday ? .registrationRequired : .futurePlanned,
                    phase: .pendingStart,
                    claim: nil,
                    retry: MeteringRetryState(
                        attemptCount: 0,
                        nextAttemptAt: request.now,
                        lastErrorCode: nil,
                        terminal: .pending
                    ),
                    createdAt: request.now
                )
                if isToday {
                    let registrationWorkID = UUID()
                    state.registrationWork[registrationWorkID] = EpochRegistrationWork(
                        workID: registrationWorkID,
                        ownerChildDeviceID: request.ownerChildDeviceID,
                        epochID: epochID,
                        routeID: routeID,
                        request: EpochRegistrationRequestDTO(
                            protocolVersion: generation.protocolVersion,
                            epochID: epochID,
                            deviceID: request.ownerChildDeviceID,
                            usageDate: usageDate,
                            timezone: generation.canonicalTimezone,
                            policyRevision: generation.policyRevision,
                            measurementSelectionDigest: generation.measurementSelectionDigest,
                            enforcementSetID: generation.enforcementSetID,
                            startedAt: request.now,
                            baseAcceptedMinutes: request.authoritativeBaseAcceptedMinutes,
                            reason: .initial
                        ),
                        claim: nil,
                        retry: MeteringRetryState(
                            attemptCount: 0,
                            nextAttemptAt: request.now,
                            lastErrorCode: nil,
                            terminal: .pending
                        ),
                        createdAt: request.now
                    )
                    if state.activeRouteID == nil {
                        state.activeEpochID = epochID
                    }
                }
                routeIDsByUsageDate[usageDate] = routeID
            }
            return MeteringHorizonPlan(
                generationID: generation.generationID,
                routeIDsByUsageDate: routeIDsByUsageDate
            )
        }
    }
}

nonisolated private func configuredCalendar(_ calendar: Calendar, timeZone: TimeZone) -> Calendar {
    _ = calendar
    var configured = Calendar(identifier: .gregorian)
    configured.locale = Locale(identifier: "en_US_POSIX")
    configured.timeZone = timeZone
    return configured
}

nonisolated private func canonicalMidnight(
    usageDate: String,
    calendar: Calendar,
    timeZone: TimeZone
) throws -> Date {
    guard usageDate.range(
        of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
        options: .regularExpression
    ) != nil else {
        throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
    }
    let parts = usageDate.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2])
    else {
        throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
    }
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = 0
    components.minute = 0
    components.second = 0
    guard let date = calendar.date(from: components),
          formattedUsageDate(date, calendar: calendar) == usageDate
    else {
        throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
    }
    return date
}

nonisolated private func calendarComponents(
    for date: Date,
    calendar: Calendar,
    timeZone: TimeZone
) -> DateComponents {
    var components = calendar.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
        from: date
    )
    components.calendar = calendar
    components.timeZone = timeZone
    return components
}

nonisolated private func formattedUsageDate(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        locale: Locale(identifier: "en_US_POSIX"),
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}
