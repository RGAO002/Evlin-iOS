/// Local "is this still matched?" signal for App Controls v2.
///
/// App Controls v2 runs on the **kid device**, which holds the Screen Time tokens
/// in `LocalAliasStore`. The iOS catalog/lazy-tag target types do NOT carry a
/// backend `token_available`/`status`/`suspected_stale` field (the lazy-tag
/// conversion discards them), so the "is this still matched?" answer is derived
/// purely from LOCAL token presence — never from a backend row field.
///
/// - `hasAliasKey`: the row has a saved catalog alias (it was bound at some point).
/// - `localTokenPresent`: the Screen Time token is currently resolvable on THIS
///   device (the alias still points at a live token).
enum MatchedState: Equatable {
    case matched
    case matchedNeedsRefresh
    case unmatched

    static func from(hasAliasKey: Bool, localTokenPresent: Bool) -> MatchedState {
        guard hasAliasKey else { return .unmatched }
        return localTokenPresent ? .matched : .matchedNeedsRefresh
    }
}
