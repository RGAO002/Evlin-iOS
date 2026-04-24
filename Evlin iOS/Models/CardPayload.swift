import Foundation
import SwiftUI

/// Reusable payload for all 8 card templates. Card-specific fields are optional.
struct CardPayload {
    let id: CardID
    let icon: String                     // SF Symbol
    let title: String
    let body: String
    let buttons: [CardButton]

    // Template variant knobs
    var checkboxes: [CardCheckboxItem]?  // MissingInfoCard (D4 variant)
    var itemList: [String]?              // BulkActionCard (A3), ListSuggestionCard (E4)
}

struct CardButton: Identifiable {
    let id = UUID()
    let label: String
    let style: Style
    let action: () -> Void

    enum Style {
        case primary
        case destructive
        case secondary
        case tertiary
        case cancel
    }
}

struct CardCheckboxItem: Identifiable {
    let id = UUID()
    let label: String
    let sublabel: String?
    var isSelected: Bool = false
}
