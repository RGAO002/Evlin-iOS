import FamilyControls

/// Isolated detection of "the kid picked all apps and categories" from a raw
/// `FamilyActivitySelection`. Kept as its own tiny surface so the eventual
/// real signal (once verified) is a one-line change at the call site inside
/// `isAllSelected(_:)` — nothing else in the app needs to change.
///
/// **Why this always returns `false` today (verified 2026-07-02):**
/// `FamilyActivitySelection.includeEntireCategory` IS a real, public property
/// on this SDK (confirmed via the iOS Simulator 26.2 SDK's
/// `FamilyControls.swiftinterface`: `public let includeEntireCategory: Bool`,
/// available iOS 15.2+). However it is NOT a live "did the user tap Select
/// All in the picker" signal — it is fixed at `FamilyActivitySelection.init`
/// time by the CALLER, not mutated by `FamilyActivityPicker` based on what
/// the user selects. This app's actual Locked-set picker
/// (`CombinedPickerSheet.swift`) deliberately constructs its picker-backing
/// selection with `FamilyActivitySelection(includeEntireCategory: false)` —
/// see the "CRITICAL" comment there explaining that assigning
/// `includeEntireCategory: true` instead would revert the picker to
/// whole-category-tap semantics, which `CombinedPickerSheet` does not want.
/// So `selection.includeEntireCategory` reads `false` for every Locked-set
/// selection this app can currently produce, regardless of whether the user
/// tapped Apple's "All Apps & Categories" affordance — it is not a usable
/// signal as wired today.
///
/// No reliable alternative exists in this codebase either: there is no
/// on-device catalog of "every known Apple activity category" to compare
/// `categoryTokens.count` against (grepped for `ActivityCategoryPolicy` /
/// `AppleFamilyControlsCategoryCatalog` — neither exists), so a
/// count-based heuristic would either under- or over-fire without a ground
/// truth to compare against.
///
/// **To wire the real signal later:** in Xcode, jump to the definition of
/// `FamilyActivitySelection` and re-check whether a newer SDK exposes a
/// live "all selected" bit, or whether `CombinedPickerSheet` can be changed
/// to seed `includeEntireCategory: true` (that comment's constraint — token
/// separation between apps/categories on tap — would need re-verifying
/// first, since it may not be compatible with treating the flag as a
/// selection-completeness signal). Once a real signal exists, change the
/// body of `isAllSelected(_:)` below — no other call site needs to change.
enum LockedSetSelectionSemantics {
    static func isAllSelected(_ selection: FamilyActivitySelection) -> Bool {
        // Safe default (see doc comment above): no reliable on-device signal
        // exists yet. Task 3's device-local token union still fixes the
        // primary "paper-thin lock" bug independent of this flag.
        false
    }
}
