import Foundation
import Observation

/// Single source of truth for the parent Home tab (spec §6.1). Replaces the
/// hardcoded `ChildProfile.all` mock. Loaded from `GET /me/profile` (the
/// authed-account aggregate that works for any signed-in parent, including a
/// pending co-parent), with `GET /family` available as the 👪 family-scoped
/// equivalent. Refreshed silently post-pairing and on pull-to-refresh.
///
/// This is the DATA layer: it holds the decoded backend DTOs (`FamilyBlockDTO`,
/// `ChildDTO`, `ParentMemberDTO`, `EnrolledDeviceDTO`, `ParentProfileDTO`). The
/// Home rewire (separate task) reads `children` / `parentDevices` / `family`
/// off this store instead of `ChildProfile.all`.
@Observable
@MainActor
final class FamilyStore {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var state: LoadState = .idle
    private(set) var family: FamilyBlockDTO?
    private(set) var children: [ChildDTO] = []
    private(set) var parents: [ParentMemberDTO] = []
    private(set) var parentDevices: [EnrolledDeviceDTO] = []
    private(set) var selfParent: ParentProfileDTO?
    private(set) var earnedSummariesByChildID: [String: APIClient.EarnedSummaryDTO] = [:]

    /// Real all-apps lock state of the single paired kid device
    /// (`evlin.childDeviceID`), refreshed alongside the family aggregate from
    /// `GET /parent/device/lock-state`. Drives the Home child card's
    /// locked/unlocked status so it reflects the device, not a stale default.
    private(set) var pairedDeviceLocked: Bool = false

    /// Presentation-layer children for the parent Home tab (spec §6.3). Maps
    /// each decoded `ChildDTO` through `ChildProfile(dto:)` so Home / settings
    /// / filter pills read real backend data instead of the retired
    /// `ChildProfile.all` mock. The child that owns the paired device carries
    /// the live lock state (`pairedDeviceLocked`). Empty when no family is
    /// loaded yet (signed-out or pre-pairing) — consumers render a placeholder.
    var childProfiles: [ChildProfile] {
        let pairedID = UserDefaults.standard.string(forKey: "evlin.childDeviceID") ?? ""
        return children.map { dto in
            ChildProfile(
                dto: dto,
                locked: pairedDeviceLocked
                    && ownsPairedDevice(childId: dto.id, pairedDeviceID: pairedID),
                earnedSummary: earnedSummariesByChildID[dto.id]
            )
        }
    }

    private let api: APIClient
    init(api: APIClient) { self.api = api }

    /// Load the full aggregate via `GET /me/profile`. Keeps the last successful
    /// snapshot on failure (spec §9: "fall back to last cached family — don't
    /// blank"). Flips `state` to `.loading` first so the UI can show a spinner.
    func load() async {
        state = .loading
        do {
            let me = try await api.fetchMeProfile()
            apply(me)
            await refreshPairedLockState()
            await refreshEarnedSummaries()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Silent refresh — does not flip to `.loading` or blank existing data.
    /// On failure, the cached snapshot is preserved; only a cold cache surfaces
    /// the error as `.failed`.
    func refresh() async {
        do {
            let me = try await api.fetchMeProfile()
            apply(me)
            await refreshPairedLockState()
            await refreshEarnedSummaries()
            state = .loaded
        } catch {
            if children.isEmpty && family == nil {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Load via the 👪 `GET /family` aggregate (family-scoped). Use when an
    /// owner/bound co-parent explicitly wants the family block (e.g. Settings).
    /// A pending co-parent (familyID == nil) would 403 here — use `load()`.
    func loadFromFamily() async {
        state = .loading
        do {
            let fam = try await api.fetchFamily()
            apply(fam)
            await refreshPairedLockState()
            await refreshEarnedSummaries()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(_ me: MeProfileResponseDTO) {
        self.selfParent = me.parent_profile
        self.family = me.family
        self.parents = me.family?.members ?? []
        self.children = me.children
        self.parentDevices = me.parent_devices
        backfillPairedChildDeviceIfMissing()
    }

    private func apply(_ fam: FamilyDTO) {
        self.family = fam.family
        self.parents = fam.family.members
        self.children = fam.children
        self.parentDevices = fam.parent_devices
        backfillPairedChildDeviceIfMissing()
    }

    /// Returning-parent recovery: after a fresh login the local
    /// `evlin.childDeviceID` is empty, so Home prompts "pair the kid's device"
    /// even though the backend aggregate already carries the paired child device
    /// (and the lock-state / CommandPoller, which read that key, stay idle).
    /// Re-derive the kid device id (+ family id) from the aggregate when the
    /// local value is missing — never clobber an explicit pairing on this device.
    private func backfillPairedChildDeviceIfMissing() {
        let key = "evlin.childDeviceID"
        let existing = UserDefaults.standard.string(forKey: key) ?? ""
        guard existing.isEmpty,
              let dev = children.first(where: { !$0.devices.isEmpty })?.devices.first
        else { return }
        UserDefaults.standard.set(dev.device_id, forKey: key)
        if let famID = family?.id, !famID.isEmpty {
            UserDefaults.standard.set(famID, forKey: "evlin.familyID")
        }
    }

    /// Look up a child by its backend id.
    func child(byId id: String) -> ChildDTO? { children.first { $0.id == id } }

    /// Cached earned-time summary for a child. Home cards and Kid's Space both
    /// read/write this cache so their time-pool bars stay on the same snapshot.
    func earnedSummary(forChildID id: String) -> APIClient.EarnedSummaryDTO? {
        earnedSummariesByChildID[id]
    }

    /// Store the latest earned-time summary for a child. This is intentionally
    /// public within the app module so detail screens can publish their fresher
    /// fetch back to Home instead of holding a divergent local-only value.
    func cacheEarnedSummary(_ summary: APIClient.EarnedSummaryDTO, forChildID id: String) {
        earnedSummariesByChildID[id] = summary
    }

    /// Fetch one child's earned-time summary and write it into the shared cache.
    /// Returns nil on failure, preserving the previous cache entry.
    func refreshEarnedSummary(forChildID id: String) async -> APIClient.EarnedSummaryDTO? {
        guard let childID = UUID(uuidString: id),
              let summary = try? await api.fetchEarnedSummary(childProfileID: childID)
        else { return nil }
        cacheEarnedSummary(summary, forChildID: id)
        return summary
    }

    /// Refresh the paired kid device's real all-apps lock state so the Home
    /// child card reflects the device (not a stale `.unlocked` default). One
    /// paired device per install (`evlin.childDeviceID`); no-op when unpaired or
    /// no family id is known. Best-effort — a failed fetch keeps the last value.
    func refreshPairedLockState() async {
        guard
            let pairedRaw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
            let deviceID = UUID(uuidString: pairedRaw),
            let famRaw = UserDefaults.standard.string(forKey: "evlin.familyID"),
            let famID = UUID(uuidString: famRaw)
        else {
            pairedDeviceLocked = false
            return
        }
        if let state = try? await api.fetchDeviceLockState(familyID: famID, childDeviceID: deviceID) {
            pairedDeviceLocked = state.locked
        }
    }

    /// Refresh child earned-time summaries used by the parent Home cards. This
    /// keeps the Home "time pool" bar on the same remaining/pool data source as
    /// the child's profile summary card.
    func refreshEarnedSummaries() async {
        guard !children.isEmpty else { return }
        let validChildIDs = Set(children.map(\.id))
        var next = earnedSummariesByChildID.filter { validChildIDs.contains($0.key) }

        for child in children {
            guard let childID = UUID(uuidString: child.id),
                  let summary = try? await api.fetchEarnedSummary(childProfileID: childID)
            else { continue }
            next[child.id] = summary
        }

        earnedSummariesByChildID = next
    }
}
