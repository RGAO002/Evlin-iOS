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
                verb: context.u1Verb ?? "unlock",
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
            if let prompt = context.reflectionPrompt,
               let essay = context.reflectionEssay,
               let mode = context.reflectionReviewMode {
                ReflectionSubmissionReviewCard(
                    childName: context.childName,
                    writingPrompt: prompt,
                    essayText: essay,
                    mode: mode,
                    redoReason: context.reflectionRedoReason,
                    status: .open,
                    onApprove: { note in
                        if let onReflectionApprove = handlers.onReflectionApprove {
                            await onReflectionApprove(note)
                        }
                    },
                    onRedo: { _ in
                        // Legacy ConfirmationCard redo handler doesn't
                        // surface the parent's note (it pre-dates the
                        // tri-state card). Future: thread the typed
                        // note through `handlers.onReflectionRedo` so
                        // this card can match the chat-side behaviour.
                        if let onReflectionRedo = handlers.onReflectionRedo {
                            await onReflectionRedo()
                        }
                    }
                )
            } else {
                EmptyView()
            }
        case .singleAppShieldAdvice, .shieldTokenMissing, .appStoreDisambiguation,
             .appNotFoundTerminal, .childDisambiguation, .categoryRenameRequired,
             .cannotBlockCategory, .categoryShieldOffer, .catalogAppInactive,
             .bundleIDRequired, .lockSelectedAppsConfirm, .lockSelectedAppsEmpty,
             .restrictionUnlockPicker:
            // Task 11/6 deterministic app-control cards never flow through
            // CardDispatcher — they render via ChatViewModel.currentAppControlCard
            // + AppControlCard. This case exists only to keep the switch
            // exhaustive after adding the new CardID cases.
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
    let u1Verb: String?
    /// "locked" or "blocked", from the backend's `verb_past` detail.
    ///
    /// The duration card used to hardcode "shielded", so a parent who said
    /// "block Facebook" was asked how long it should be *shielded* — naming a
    /// different action than the one they asked for. Optional and defaulted:
    /// when absent the copy falls back to the lock wording, which is correct
    /// for every caller that does not deal in blocks.
    let verbPast: String?
    var reflectionPrompt: String?
    var reflectionEssay: String?
    var reflectionReviewMode: ReflectionReviewMode?
    var reflectionRedoReason: String?

    init(
        targetDisplay: String,
        childName: String,
        durationMinutes: Int?,
        categoryGuess: String?,
        listSuggestions: [String],
        existingLists: [String],
        blockItems: [String],
        childDevices: [(id: UUID, label: String)],
        mode: String,
        existingRecordKey: String?,
        requestedExpiryISO: String?,
        existingMode: String?,
        u1Token: String?,
        u1ShieldList: [U1ShieldEntry],
        u1Verb: String? = nil,
        verbPast: String? = nil,
        reflectionPrompt: String? = nil,
        reflectionEssay: String? = nil,
        reflectionReviewMode: ReflectionReviewMode? = nil,
        reflectionRedoReason: String? = nil
    ) {
        self.targetDisplay = targetDisplay
        self.childName = childName
        self.durationMinutes = durationMinutes
        self.categoryGuess = categoryGuess
        self.listSuggestions = listSuggestions
        self.existingLists = existingLists
        self.blockItems = blockItems
        self.childDevices = childDevices
        self.mode = mode
        self.existingRecordKey = existingRecordKey
        self.requestedExpiryISO = requestedExpiryISO
        self.existingMode = existingMode
        self.u1Token = u1Token
        self.u1ShieldList = u1ShieldList
        self.u1Verb = u1Verb
        self.verbPast = verbPast
        self.reflectionPrompt = reflectionPrompt
        self.reflectionEssay = reflectionEssay
        self.reflectionReviewMode = reflectionReviewMode
        self.reflectionRedoReason = reflectionRedoReason
    }
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
            u1Token: nil, u1ShieldList: [], u1Verb: nil
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
    var onReflectionApprove: ((String) async -> Void)?
    var onReflectionRedo: (() async -> Void)?
}
