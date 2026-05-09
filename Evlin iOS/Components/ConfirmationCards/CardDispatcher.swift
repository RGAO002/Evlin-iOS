import SwiftUI

/// Chooses which template renders a given CardID and builds the payload
/// from backend-provided context.
struct CardDispatcher: View {
    let cardID: CardID
    let context: CardContext
    let handlers: CardHandlers

    var body: some View {
        let payload = buildPayload()
        switch cardID {
        case .A1, .D3: DangerConfirmCard(payload: payload)
        case .A3: BulkActionCard(payload: payload)
        case .B1, .B2, .C1, .C2: ReplaceModeCard(payload: payload)
        case .D1:
            MissingInfoCard(payload: payload)
        case .D4:
            // D4 wires checkbox selections back via onCheckboxesConfirmed.
            MissingInfoCard(payload: payload, onCheckboxesConfirmed: { selected in
                handlers.onChildrenLabelsPicked?(selected)
            })
        case .D2: AmbiguityCard(payload: payload)
        case .E1, .E2, .G1: UnsupportedInModeCard(payload: payload)
        case .E3: CatalogMissCard(payload: payload)
        case .E4, .F1: ListSuggestionCard(payload: payload)
        case .R1: DangerConfirmCard(payload: payload)
        case .U1:
            U1Card(
                entries: context.u1ShieldList,
                onUnlockSelected: { indices in
                    handlers.onU1UnlockSelected?(indices)
                },
                onUnlockEverything: { handlers.onU1UnlockEverything?() },
                onCancel: { handlers.onCancel?() }
            )
        case .contentGenFailed:
            // Phase 2B: ReflectionContentFailedCard.
            // onPrimary  → Retry  (patch intent_confirmed: true)
            // onSecondary → Use simpler template  (patch use_simpler_template: true)
            // onCancel   → Cancel
            ReflectionContentFailedCard(
                payload: payload,
                onRetry: { handlers.onPrimary?() },
                onSimplerTemplate: { handlers.onSecondary?() },
                onCancel: { handlers.onCancel?() }
            )
        case .reflectionReview:
            // Phase 2B: adapter returns nil for confirm_approve / confirm_redo,
            // so this branch is dead — PlanArchCardView handles those via fallback.
            // Phase 2C will add ReflectionReviewCard and route here.
            EmptyView()
        }
    }

    private func buildPayload() -> CardPayload {
        CardPayloadBuilder.build(cardID: cardID, context: context, handlers: handlers)
    }
}

/// Inputs to build a card payload.
struct CardContext {
    let targetDisplay: String           // "Instagram", "list 1", etc.
    let childName: String               // "Liam"
    let durationMinutes: Int?
    let categoryGuess: String?          // For E1, E3 fallback
    let listSuggestions: [String]
    let existingLists: [String]         // For E4
    let blockItems: [String]            // For A3
    let childDevices: [(id: UUID, label: String)]  // For D4
    let mode: String                    // "std" or "max" — drives copy variants (E1)
    // For B1 round-trip (see plan Phase 6/9):
    let existingRecordKey: String?
    let requestedExpiryISO: String?
    let existingMode: String?
    // For U1 unlock-disambiguation card:
    let u1Token: String?
    let u1ShieldList: [U1ShieldEntry]
}

extension CardContext {
    static func defaultContext(targetDisplay: String, childName: String) -> CardContext {
        CardContext(
            targetDisplay: targetDisplay, childName: childName,
            durationMinutes: nil, categoryGuess: nil,
            listSuggestions: [], existingLists: [],
            blockItems: [], childDevices: [],
            mode: "std",
            existingRecordKey: nil, requestedExpiryISO: nil, existingMode: nil,
            u1Token: nil, u1ShieldList: []
        )
    }
}

/// Handlers wired by ChatViewModel when rendering.
struct CardHandlers {
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onTertiary: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDurationPicked: ((Int?) -> Void)?   // nil = permanent (D1)
    var onChildrenPicked: (([UUID]) -> Void)?  // D4 (by id — deferred)
    /// D4 primary confirm — passes the selected child labels (e.g. ["Liam"])
    /// so ChatViewModel can rewrite the parent message to include the child's
    /// name. Preferred over `onChildrenPicked` until we plumb UUID mapping.
    var onChildrenLabelsPicked: (([String]) -> Void)?
    var onListPicked: ((String) -> Void)?      // F1
    var onU1UnlockSelected: (([Int]) -> Void)?
    var onU1UnlockEverything: (() -> Void)?
}
