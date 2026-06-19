/// Pure decision for what the App Controls v2 save path must do when the user
/// edits the onboarding "default lock group" (adds/removes apps/categories).
///
/// The branch turns only on whether the group is currently active (locked):
///   - active   → caller re-applies the lock from the new selection via
///                `DefaultGroupLockApplier.apply(...)`, which calls
///                `ActiveLockStore.addShield(force: true)`. `force` OVERWRITES
///                the record's token sets, so on recompute a removed member
///                drops out and an added one appears.
///   - inactive → caller only persists the new selection blob; no shield work.
///
/// This type is the decision ONLY. The real token-level add/remove shielding is
/// verified on-device — tokens can't be minted off-device, so it can't be unit
/// tested here. The Phase-3 save path (once App Controls v2 exists) will call
/// `action(active:)` and then either invoke `DefaultGroupLockApplier.apply(...)`
/// (`.reapplyWithForce`) or just persist the selection blob (`.blobOnly`).
enum GroupEditReconciler {
    enum Action: Equatable {
        case reapplyWithForce   // group is active → caller re-applies the lock from the new selection
        case blobOnly           // group inactive → caller only saves the selection blob
    }
    static func action(active: Bool) -> Action {
        active ? .reapplyWithForce : .blobOnly
    }
}
