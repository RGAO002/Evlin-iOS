import Combine
import FamilyControls
import Foundation

/// Shared capture logic for the all-category selection used by v2 metering.
@MainActor
final class TrackingSelectionCapture: ObservableObject {
    enum State: Equatable {
        case idle
        case needsSelection
        case notAuthorized
        case saved
    }

    @Published var selection = FamilyActivitySelection(includeEntireCategory: true)
    @Published private(set) var state: State = .idle

    /// Family Controls tokens are opaque, so tests cannot construct a non-empty
    /// selection without this narrow seam.
    private let overrideIsSelectionEmpty: (() -> Bool)?

    init(isSelectionEmpty: (() -> Bool)? = nil) {
        overrideIsSelectionEmpty = isSelectionEmpty
    }

    nonisolated deinit {}

    private var selectionIsEmpty: Bool {
        if let overrideIsSelectionEmpty { return overrideIsSelectionEmpty() }
        return selection.applicationTokens.isEmpty
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
    }

    func requestPicker(authorized: Bool) -> Bool {
        guard authorized else {
            state = .notAuthorized
            return false
        }
        state = .idle
        return true
    }

    func commit() {
        guard !selectionIsEmpty else {
            state = .needsSelection
            return
        }
        EarnedTimeStore.shared.saveMeasurementSelection(selection)
        // This retains the existing identity-transition reconciliation. V2
        // installation is performed explicitly by commit(then:).
        EarnedBudgetArming.armIfReady()
        state = .saved
    }

    func commit(then recoverV2: @escaping () async -> Void) async {
        commit()
        guard state == .saved else { return }
        await recoverV2()
    }
}
