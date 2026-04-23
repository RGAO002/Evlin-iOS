import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

final class ActionExecutor: @unchecked Sendable {
    static let shared = ActionExecutor()

    private let activityCenter = DeviceActivityCenter()

    func execute(_ cmd: LockCommand, blob: Data? = nil) async -> AckResult {
        // Read live auth status (not cached) — ScreenTimeManager.shared.isAuthorized
        // is set only at init time and won't reflect authorization granted later.
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return .failed(.notAuthorized)
        }

        switch cmd.action {
        case .unlockAll:
            await ActiveLockStore.shared.removeAll()
            cancelAllScheduled()
            return .confirmedExact(displayName: "All locks cleared")

        case .unlock:
            let removed = await ActiveLockStore.shared.removeMatching(cmd.target)
            removed.forEach(cancelScheduled)
            if removed.isEmpty { return .failed(.nothingToUnlock) }
            return .confirmedExact(displayName: cmd.target.targetDisplay ?? cmd.target.originalRequest)

        case .expandLibrary:
            // UI-side flow handles this; executor returns failed placeholder.
            return .failed(.execution("expand_library handled in UI"))

        case .lock:
            break
        }

        do {
            let lock = try buildLock(from: cmd, blob: blob)
            await ActiveLockStore.shared.add(lock)
            if cmd.durationMinutes != nil, let expires = lock.expiresAt {
                try scheduleRelock(commandID: lock.id, expiresAt: expires)
            }
            switch cmd.tier {
            case .category:
                return .confirmedFallback(
                    displayName: lock.displayName,
                    category: cmd.target.categoryHint ?? "unknown",
                    origRequest: cmd.target.originalRequest
                )
            default:
                return .confirmedExact(displayName: lock.displayName)
            }
        } catch let err as ExecuteError {
            return .failed(err.ackFailure)
        } catch {
            return .failed(.execution(error.localizedDescription))
        }
    }

    private func buildLock(from cmd: LockCommand, blob: Data?) throws -> ActiveLock {
        guard let tier = cmd.tier else { throw ExecuteError.malformed }
        switch tier {
        case .exactBundle:
            guard let bid = cmd.target.bundleID else { throw ExecuteError.malformed }
            return ActiveLock(
                id: cmd.id, tier: .exactBundle,
                blockedBundleIDs: [bid],
                shieldAppTokens: [], shieldCategoryTokens: [],
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.targetDisplay ?? bid
            )
        case .savedList:
            let sel: FamilyActivitySelection
            if let blob = blob,
               let decoded = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: blob) {
                sel = decoded
            } else if let name = cmd.target.listName,
                      let local = LocalAliasStore.shared.savedList(named: name) {
                sel = local
            } else {
                throw ExecuteError.listNotFound(cmd.target.listName ?? "(unnamed)")
            }
            return ActiveLock(
                id: cmd.id, tier: .savedList,
                blockedBundleIDs: [],
                shieldAppTokens: sel.applicationTokens,
                shieldCategoryTokens: sel.categoryTokens,
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: cmd.target.listName ?? "saved list"
            )
        case .category:
            guard let hint = cmd.target.categoryHint,
                  let tok = LocalAliasStore.shared.categoryToken(forName: hint)
            else { throw ExecuteError.categoryNotConfigured(cmd.target.categoryHint ?? "unknown") }
            return ActiveLock(
                id: cmd.id, tier: .category,
                blockedBundleIDs: [],
                shieldAppTokens: [],
                shieldCategoryTokens: [tok],
                issuedAt: cmd.issuedAt, expiresAt: cmd.expiresAt,
                originalRequest: cmd.target.originalRequest,
                displayName: hint.capitalized
            )
        }
    }

    // MARK: - DeviceActivity scheduling

    private func scheduleRelock(commandID: UUID, expiresAt: Date) throws {
        let calendar = Calendar.current
        let now = Date()
        let startComp = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComp = calendar.dateComponents([.hour, .minute, .second], from: expiresAt)
        let schedule = DeviceActivitySchedule(intervalStart: startComp, intervalEnd: endComp, repeats: false)
        let name = DeviceActivityName("evlin.lock.\(commandID.uuidString)")
        try activityCenter.startMonitoring(name, during: schedule)
    }

    private func cancelScheduled(_ commandID: UUID) {
        let name = DeviceActivityName("evlin.lock.\(commandID.uuidString)")
        activityCenter.stopMonitoring([name])
    }

    private func cancelAllScheduled() {
        activityCenter.stopMonitoring()
    }
}

enum ExecuteError: Error {
    case malformed
    case listNotFound(String)
    case categoryNotConfigured(String)

    var ackFailure: AckFailure {
        switch self {
        case .malformed: return .malformed
        case .listNotFound(let n): return .listNotFound(n)
        case .categoryNotConfigured(let n): return .categoryNotConfigured(n)
        }
    }
}
