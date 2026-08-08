/// Local "is this still matched?" signal for App Controls v2.
///
/// App Controls v2 runs on the **kid device**, which holds the Screen Time tokens
/// in `LocalAliasStore`. The iOS catalog/lazy-tag target types do NOT carry a
/// backend `token_available`/`status`/`suspected_stale` field (the lazy-tag
/// conversion discards them), so this state combines local token presence with
/// the child-device identity for which the backend confirmed the match.
///
/// - `hasAliasKey`: the row has a saved catalog alias (it was bound at some point).
/// - `localTokenPresent`: the Screen Time token is currently resolvable on THIS
///   device (the alias still points at a live token).
/// - `currentDeviceCatalogConfirmed`: the backend catalog ID came back for the
///   currently paired child-device row, not a previous family/device row.
enum MatchedState: Equatable {
    case matched
    case matchedNeedsRefresh
    case unmatched

    static func from(
        hasAliasKey: Bool,
        localTokenPresent: Bool,
        currentDeviceCatalogConfirmed: Bool
    ) -> MatchedState {
        guard hasAliasKey else { return .unmatched }
        return localTokenPresent && currentDeviceCatalogConfirmed
            ? .matched
            : .matchedNeedsRefresh
    }
}
