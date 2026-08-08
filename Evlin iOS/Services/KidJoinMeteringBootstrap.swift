import Foundation
import DeviceActivity

@MainActor
enum AppLimitPairingIdentityConvergence {
    @discardableResult
    static func run(ownerChildDeviceID: UUID) -> Bool {
        run(
            ownerChildDeviceID: ownerChildDeviceID,
            store: .shared,
            scheduler: makeDefaultDeviceActivityScheduler()
        )
    }

    @discardableResult
    static func run(
        ownerChildDeviceID: UUID,
        store: AppLimitEpochStore,
        scheduler: any DeviceActivityScheduling
    ) -> Bool {
        do {
            guard let replacement = try store.convergeOwnerAfterPairing(
                expectedOwner: ownerChildDeviceID
            ) else { return false }

            let liveAppLimitNames = scheduler.monitoredActivities()
                .map(\.rawValue)
                .filter {
                    $0.hasPrefix(AppLimitPlanner.v2ActivityPrefix)
                        || $0.hasPrefix(AppLimitPlanner.windowActivityPrefix)
                }
            let namesToStop = replacement.oldActivityNames
                .union(liveAppLimitNames)
                .sorted()
            if !namesToStop.isEmpty {
                scheduler.stopMonitoring(
                    namesToStop.map { DeviceActivityName($0) }
                )
            }
            MeteringFlightRecorder.emit(
                kind: .meteringRearm,
                source: .perAppLimit,
                site: "app_limit.owner_convergence",
                verdict: "replaced_stale_owner",
                detail: MeteringFlightRecorder.detail([
                    ("old_owner", replacement.oldOwner?.uuidString ?? "missing"),
                    ("new_owner", ownerChildDeviceID.uuidString),
                    ("stopped", "\(namesToStop.count)"),
                ])
            )
            return true
        } catch {
            MeteringFlightRecorder.emitError(
                site: "app_limit.owner_convergence",
                error: error
            )
            return false
        }
    }
}

/// Orders the production-only handoff that follows a successful kid pairing.
/// The retained on-device App Controls selection is valid for this hardware,
/// but its backend list and the metering owner are scoped to the newly adopted
/// child-device identity. Publishing the lock selection before the first
/// command poll prevents an already-exhausted profile from briefly having no
/// shield target after pairing. It does not provide the independent Screen
/// Time Tracking selection; a missing tracking selection stays visibly
/// incomplete until the parent captures it on the kid device.
@MainActor
struct KidJoinMeteringBootstrap {
    let prepareIdentity: (UUID) -> Void
    let convergeAppLimitIdentity: (UUID) -> Void
    let publishSelection: () async -> Bool
    let publishMatchedCatalog: () async -> Bool
    let recoverMetering: () async -> Void
    let startCommandOwner: (UUID) -> Void

    func run(for childDeviceID: UUID) async {
        prepareIdentity(childDeviceID)
        convergeAppLimitIdentity(childDeviceID)
        _ = await publishSelection()
        _ = await publishMatchedCatalog()
        await recoverMetering()
        startCommandOwner(childDeviceID)
    }
}
