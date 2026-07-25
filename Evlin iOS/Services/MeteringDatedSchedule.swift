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
    // Re-exported from `MeteringLadderMath` (which owns the cut) so the two can
    // never drift; `EarnedBudgetScheduler` reads them from here.
    static let earnedBucketMinutes = MeteringLadderMath.bucketMinutes
    static let guardEventCount = MeteringLadderMath.guardEventCount

    /// Most application tokens one `DeviceActivityEvent` may carry. Beyond this
    /// the event silently never fires (observed 2026-07-24; `AppLimitPlanner`
    /// enforces the same bound for its own windows). Named rather than inline so
    /// the number is greppable from both stacks when it is finally confirmed.
    static let applicationTokenCap = 50

    /// The 2026-07-24 A/B that capped this at 2 events ("activities carrying
    /// 12-25 thresholds never fire, 1-2 event ones do") measured the interval
    /// anchor bug, not the event count: with the interval pinned to canonical
    /// midnight, every rung below the day's existing ledger was already behind
    /// Apple's counter, so a long ladder looked dead while a short one — whose
    /// two rungs Apple back-delivered once at arm time — looked alive. Now that
    /// today's interval starts at `now`, every rung is genuinely ahead of the
    /// counter, so the full ladder is armed again.
    ///
    /// The arithmetic itself lives in `MeteringLadderMath` because
    /// `DeviceEpochStore` re-cuts ladders and is linked into targets this file
    /// is not a member of (`EvlinPushApplier`).
    static func thresholds(poolMinutes: Int, capMinutes: Int) -> [Int] {
        MeteringLadderMath.thresholds(remainingMinutes: min(poolMinutes, capMinutes))
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
        intervalStartAt: Date? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DeviceActivitySchedule {
        let policyCalendar = configuredCalendar(calendar, timeZone: timeZone)
        let canonicalStart = try canonicalMidnight(
            usageDate: usageDate,
            calendar: policyCalendar,
            timeZone: timeZone
        )
        guard let end = policyCalendar.date(byAdding: .day, value: 1, to: canonicalStart) else {
            throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
        }
        let start = intervalStartAt ?? canonicalStart
        guard start >= canonicalStart, start < end else {
            throw MeteringDatedScheduleError.invalidUsageDate(usageDate)
        }
        return DeviceActivitySchedule(
            intervalStart: calendarComponents(for: start, calendar: policyCalendar, timeZone: timeZone),
            intervalEnd: calendarComponents(for: end, calendar: policyCalendar, timeZone: timeZone),
            repeats: false
        )
    }

    static func canonicalStart(
        usageDate: String,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> Date {
        let policyCalendar = configuredCalendar(calendar, timeZone: timeZone)
        return try canonicalMidnight(
            usageDate: usageDate,
            calendar: policyCalendar,
            timeZone: timeZone
        )
    }

    /// True once `now` is at or past the canonical END of `usageDate`.
    ///
    /// Apple rejects `startMonitoring` for an interval that has already
    /// finished with `invalidDateComponents` — reproduced on iPhone 2026-07-25,
    /// where the watchdog kept trying to re-kick YESTERDAY's route (the device
    /// was wedged on the previous day) and threw on every attempt. Nothing may
    /// arm a day that is over, so this is the one shared predicate every arming
    /// path consults.
    ///
    /// A usage date this calendar cannot parse returns `true`: an unusable date
    /// is never safe to arm.
    static func hasElapsed(
        usageDate: String,
        timeZone: TimeZone,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        let policyCalendar = configuredCalendar(calendar, timeZone: timeZone)
        guard let start = try? canonicalMidnight(
            usageDate: usageDate,
            calendar: policyCalendar,
            timeZone: timeZone
        ), let end = policyCalendar.date(byAdding: .day, value: 1, to: start) else {
            return true
        }
        return now >= end
    }

    static func makeEvent(
        selection: FamilyActivitySelection,
        thresholdMinutes: Int
    ) -> DeviceActivityEvent {
        precondition(thresholdMinutes > 0, "Metering event threshold must be positive")
        // DIAGNOSTIC FIX (2026-07-24): events carrying >50 application tokens
        // never fire (iPhone 40 apps fired all day; iPad 180 apps never fired;
        // AppLimitPlanner already enforces <=50 tokens/window). Cap apps at 50 —
        // the category tokens still cover every app, so coverage semantics hold.
        //
        // Applies to EVERY configuration, deliberately. It was `#if DEBUG` until
        // 2026-07-25, which inverted the risk: every on-device build we have ever
        // verified is a Debug one, so Release alone would have shipped the
        // uncapped path — the exact shape that produced the silent iPad. Whether
        // 50 is truly Apple's limit is still unconfirmed (see the backlog item);
        // until it is, both configurations run the behaviour we have evidence for.
        var applications = selection.applicationTokens
        if applications.count > applicationTokenCap {
            applications = Set(Array(applications).prefix(applicationTokenCap))
        }
        return DeviceActivityEvent(
            applications: applications,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: thresholdMinutes),
            // Count only usage that happens AFTER this monitor starts.
            //
            // The ladder is cut over `remaining = pool - baseAcceptedMinutes`, so
            // a rung means "N more minutes from here", and `authorizeV2Callback`
            // enforces exactly that (a rung may not be credited before N minutes
            // of wall clock have passed since `epoch.startedAt`). With
            // `includesPastActivity: true` the daemon instead compared the rungs
            // against the whole interval's ledger, so a mid-day arm fired every
            // rung within ~1s — and those deliveries were then correctly rejected
            // as `too_early`, one per rung, never to be re-sent. Apple's counter
            // and this ladder now measure the same thing; minutes spent before
            // this monitor existed stay accounted for in `baseAcceptedMinutes`.
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
            var generation = activeMatch ?? deterministicMatch ?? MeteringPolicyGeneration(
                generationID: UUID(),
                protocolVersion: request.generationKey.protocolVersion,
                childDeviceID: request.generationKey.childDeviceID,
                canonicalTimezone: request.generationKey.canonicalTimezone,
                policyRevision: request.generationKey.policyRevision,
                measurementSelectionDigest: request.generationKey.measurementSelectionDigest,
                enforcementSetID: request.generationKey.enforcementSetID,
                measurementSelectionBytes: request.persistedSelectionBytes,
                createdAt: request.now,
                retiredAt: nil,
                configuredPoolMinutes: request.poolMinutes,
                configuredDeviceCapMinutes: request.deviceCapMinutes
            )
            if generation.configuredPoolMinutes == nil {
                generation.configuredPoolMinutes = request.poolMinutes
            }
            if generation.configuredDeviceCapMinutes == nil {
                generation.configuredDeviceCapMinutes = request.deviceCapMinutes
            }
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
                        calendarIdentifier: "gregorian",
                        // Today's monitor must measure from NOW, not from
                        // canonical midnight.
                        //
                        // Apple counts a `includesPastActivity: true` event from
                        // the interval start, while this ladder is cut over
                        // `remaining = pool - baseAcceptedMinutes` — i.e. it means
                        // "N more minutes from here". Starting the interval at
                        // midnight makes those two disagree by exactly the
                        // minutes already spent today, so every rung of a
                        // mid-day (re)arm is already behind the daemon's counter:
                        // Apple back-delivers them once, ~1s after
                        // startMonitoring, and then nothing fires for the rest of
                        // the day. That is why a parent changing any setting
                        // during the day silently stopped the pool until
                        // midnight, and why the debug re-kick button was the only
                        // way back. Anchoring at `now` makes the daemon measure
                        // the same thing the ladder promises; minutes already
                        // spent are preserved in `baseAcceptedMinutes`.
                        //
                        // Future days plan at midnight as before (`now` is not
                        // inside their interval anyway).
                        intervalStartAt: isToday ? request.now : nil
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
                    createdAt: request.now,
                    // The base these thresholds were cut against — the same
                    // number the epoch is born with, recorded so a later base
                    // move can never silently re-price the rungs (BUG 1).
                    ladderBaseMinutes: isToday ? request.authoritativeBaseAcceptedMinutes : 0
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
