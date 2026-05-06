// Evlin iOS/Models/LazyTagRequest.swift
//
// Drives `.sheet(item:)` in ChatView. `id` is the ProposalDTO.token of the
// proposal that triggered the tag flow — that token doubles as a stable
// identifier for the proposal AND satisfies Identifiable for SwiftUI's
// item-based sheet presentation.

import Foundation

struct LazyTagRequest: Identifiable, Equatable {
    let id: String       // proposalToken
    let target: String   // e.g. "Instagram"
    let kind: AliasKind
}
