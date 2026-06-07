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
    }

    private func apply(_ fam: FamilyDTO) {
        self.family = fam.family
        self.parents = fam.family.members
        self.children = fam.children
        self.parentDevices = fam.parent_devices
    }

    /// Look up a child by its backend id.
    func child(byId id: String) -> ChildDTO? { children.first { $0.id == id } }
}
