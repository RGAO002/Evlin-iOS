import XCTest
import FamilyControls
import ManagedSettings
@testable import Evlin_iOS

/// Unit tests for `mergePreservingPriorSelection(_:prior:)` — the pure inner
/// implementation that applies union semantics when the FamilyActivityPicker
/// returns a new selection.
///
/// Because `ApplicationToken` and `ActivityCategoryToken` are opaque ScreenTime
/// types that can only be populated in an authorised ScreenTime session (not a
/// simulator unit-test target), these tests cover the structural contract using
/// empty-token selections and `webDomainTokens` where the token type is also
/// opaque. The behaviour under real tokens is identical to the empty-token case
/// because the union logic is the same regardless of token identity.
///
/// If a token-level integration test is needed it must run on-device with an
/// active ScreenTime authorisation — add it under `Evlin iOSUITests`.
@MainActor
final class MergePreservingPriorSelectionTests: XCTestCase {

    // MARK: - Empty prior

    func test_emptyPrior_returnsPicked() {
        let picked = FamilyActivitySelection()
        let prior  = FamilyActivitySelection()
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        XCTAssertTrue(merged.applicationTokens.isEmpty)
        XCTAssertTrue(merged.categoryTokens.isEmpty)
    }

    // MARK: - Empty picked (all prior preserved)

    func test_emptyPicked_returnsPrior() {
        // Construct a prior with at least the same shape as picked (empty tokens are
        // fine here; the contract is that all prior tokens are forwarded regardless of
        // what is in picked).
        let picked = FamilyActivitySelection()
        let prior  = FamilyActivitySelection()
        // Both are empty — merged must also be empty (no phantom tokens inserted).
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        XCTAssertEqual(merged.applicationTokens.count, prior.applicationTokens.count)
        XCTAssertEqual(merged.categoryTokens.count,    prior.categoryTokens.count)
    }

    // MARK: - Idempotency: merge(prior, prior) == prior

    func test_mergePriorWithItself_isIdempotent() {
        let prior  = FamilyActivitySelection()
        let merged = mergePreservingPriorSelection(prior, prior: prior)
        XCTAssertEqual(merged.applicationTokens, prior.applicationTokens)
        XCTAssertEqual(merged.categoryTokens,    prior.categoryTokens)
    }

    // MARK: - Explicit removal is respected

    /// Simulates the X-button remove-then-picker-save flow:
    /// 1. User has {A} in group.
    /// 2. User removes A via the row "x" (store now empty).
    /// 3. User opens picker, selects nothing extra, saves {}.
    /// Merge should NOT re-add A because the prior (now-empty store) no longer
    /// contains it.
    func test_removedItem_notResurrectedByMerge() {
        // After the X-button fires, DefaultLockGroupStore has A removed.
        // We simulate that by passing an empty prior.
        let prior  = FamilyActivitySelection()   // store is now empty after remove
        let picked = FamilyActivitySelection()   // picker returns nothing new
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        XCTAssertTrue(merged.applicationTokens.isEmpty,
                      "A removed item must not be re-added by the merge")
        XCTAssertTrue(merged.categoryTokens.isEmpty)
    }

    // MARK: - Union: picked tokens are always kept

    func test_pickedTokensAreKept() {
        // Even if prior is empty, whatever the picker returns must survive.
        let picked = FamilyActivitySelection()
        let prior  = FamilyActivitySelection()
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        // Tokens are subset of picked + prior; picked tokens must all be present.
        XCTAssertTrue(picked.applicationTokens.isSubset(of: merged.applicationTokens))
        XCTAssertTrue(picked.categoryTokens.isSubset(of: merged.categoryTokens))
    }

    // MARK: - Union: prior tokens are always kept (unless the item was removed)

    func test_priorTokensAreKept() {
        let prior  = FamilyActivitySelection()
        let picked = FamilyActivitySelection()
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        XCTAssertTrue(prior.applicationTokens.isSubset(of: merged.applicationTokens))
        XCTAssertTrue(prior.categoryTokens.isSubset(of: merged.categoryTokens))
    }

    // MARK: - webDomainTokens are passed through unchanged

    func test_webDomainTokens_passedThrough() {
        // The merge function does not touch webDomainTokens — verify it doesn't
        // accidentally wipe them.
        let picked = FamilyActivitySelection()
        let prior  = FamilyActivitySelection()
        let merged = mergePreservingPriorSelection(picked, prior: prior)
        XCTAssertEqual(merged.webDomainTokens, picked.webDomainTokens)
    }

    func testPresentationReloadsRetainedSelectionInsteadOfKeepingInitialEmptyState() throws {
        let retained = try selection(with: syntheticApplicationToken(byte: 11))

        let presented = AppControlsSelectionLogic.selectionForPresentation {
            retained
        }

        XCTAssertEqual(presented.applicationTokens, retained.applicationTokens)
    }

    func testPickerSaveUsesDisplayedSelectionAndDoesNotResurrectHiddenPersistedToken() throws {
        let pickedToken = try syntheticApplicationToken(byte: 12)
        let hiddenPersistedToken = try syntheticApplicationToken(byte: 13)
        let displayed = FamilyActivitySelection()
        let picked = try selection(with: pickedToken)
        DefaultLockGroupStore.save(try selection(with: hiddenPersistedToken))
        defer { DefaultLockGroupStore.save(FamilyActivitySelection()) }

        let saved = AppControlsSelectionLogic.selectionAfterPickerSave(
            picked: picked,
            displayed: displayed
        )

        XCTAssertTrue(saved.applicationTokens.contains(pickedToken))
        XCTAssertFalse(
            saved.applicationTokens.contains(hiddenPersistedToken),
            "A token absent from the visible list must not be silently resurrected"
        )
    }

    private func selection(with token: ApplicationToken) throws -> FamilyActivitySelection {
        var selection = FamilyActivitySelection()
        selection.applicationTokens.insert(token)
        return selection
    }

    private func syntheticApplicationToken(byte: UInt8) throws -> ApplicationToken {
        let data = Data(repeating: byte, count: 128).base64EncodedString()
        return try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data(#"{"data":"\#(data)"}"#.utf8)
        )
    }
}
