import XCTest
@testable import Evlin_iOS

/// Wave-1 Task 5: the "immortal lock" bug. The extension writes
/// `savedList:<lockedSetID>` using the backend's LOWERCASE UUID string; the
/// parent unlock path (`ActionExecutor.executeUnshield`) builds the same key
/// via `id.uuidString`, which Swift renders UPPERCASE. The two keys never
/// match, so `removeSource`/`removeShield` silently miss the dict entry and
/// the shield is never removed — the parent's unlock button stays red forever.
///
/// Fix: `ShieldRecord.makeRecordKey` lowercases the `.savedList` targetKey
/// segment (only that tier — its targetKey is always a UUID string). A
/// one-time sweep in `ActiveLockStore.restore()` re-keys any already-persisted
/// `savedList:`-cased records to lowercase, merging with a lowercase twin if
/// one already exists.
final class RecordKeyNormalizationTests: XCTestCase {

    // MARK: - Fixture (memberwise, empty token sets — mirrors CommandPollerEffectiveStateTests)

    private func makeRecord(
        recordKey: String,
        tier: ShieldTier,
        targetKey: String,
        sources: Set<ShieldSource>
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: recordKey,
            tier: tier,
            targetKey: targetKey,
            displayName: "Locked Set",
            lastCommandID: UUID(),
            appTokens: [],
            categoryTokens: [],
            webDomainTokens: [],
            appliesToAll: false,
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000),
            expiresAt: nil,
            originalRequest: "test",
            targetChildID: UUID(),
            sources: sources
        )
    }

    // MARK: 1. makeRecordKey lowercases the savedList targetKey

    func test_makeRecordKey_savedList_lowercasesUUID() {
        let key = ShieldRecord.makeRecordKey(
            tier: .savedList,
            targetKey: "D6510F2A-DBF0-4EF5-A21D-B4F78D3374CF"
        )
        XCTAssertEqual(key, "savedList:d6510f2a-dbf0-4ef5-a21d-b4f78d3374cf")
    }

    // MARK: 2. Other tiers pass through unchanged

    func test_makeRecordKey_otherTiers_passThroughUnchanged() {
        XCTAssertEqual(
            ShieldRecord.makeRecordKey(tier: .exactApp, targetKey: "com.foo.Bar"),
            "exactApp:com.foo.Bar"
        )
        XCTAssertEqual(
            ShieldRecord.makeRecordKey(tier: .category, targetKey: "social"),
            "category:social"
        )
        XCTAssertEqual(
            ShieldRecord.makeRecordKey(tier: .allApps, targetKey: "all"),
            "allApps:all"
        )
        XCTAssertEqual(
            ShieldRecord.makeRecordKey(tier: .all, targetKey: "ignored"),
            "all"
        )
    }

    // MARK: 3. Round-trip: lowercase-stored record is found/removed via an uppercase-built key

    func test_roundTrip_uppercaseBuiltKey_removesLowercaseStoredRecord() {
        let idString = "D6510F2A-DBF0-4EF5-A21D-B4F78D3374CF"
        let id = UUID(uuidString: idString)!

        // Extension writes the record keyed by the backend's lowercase string.
        let storedKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: idString.lowercased())
        var dict: [String: ShieldRecord] = [
            storedKey: makeRecord(
                recordKey: storedKey,
                tier: .savedList,
                targetKey: idString.lowercased(),
                sources: [.earnedTime]
            )
        ]

        // Parent unlock path builds the key from `id.uuidString` (uppercase).
        let removerKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: id.uuidString)

        XCTAssertEqual(removerKey, storedKey, "normalized keys must match regardless of input case")

        dict = ShieldSourceLogic.removingSource(.earnedTime, fromRecordKey: removerKey, in: dict)
        XCTAssertTrue(dict.isEmpty, "the record must be found and removed via the normalized key")
    }

    // MARK: 4. Migration sweep: merges an upper-cased legacy key into its lowercase twin

    func test_sweep_mergesUppercaseTwin_intoLowercaseRecord_unioningSources() {
        let idString = "D6510F2A-DBF0-4EF5-A21D-B4F78D3374CF"
        let upperKey = "savedList:\(idString)"
        let lowerKey = "savedList:\(idString.lowercased())"

        let upperRecord = makeRecord(
            recordKey: upperKey,
            tier: .savedList,
            targetKey: idString,
            sources: [.manual]
        )
        let lowerRecord = makeRecord(
            recordKey: lowerKey,
            tier: .savedList,
            targetKey: idString.lowercased(),
            sources: [.earnedTime]
        )

        let dict: [String: ShieldRecord] = [upperKey: upperRecord, lowerKey: lowerRecord]
        let swept = ScreenTimeRecordKeySweep.sweep(dict)

        XCTAssertEqual(swept.count, 1, "the upper-cased twin must be merged away")
        let merged = try? XCTUnwrap(swept[lowerKey])
        XCTAssertEqual(merged?.recordKey, lowerKey)
        XCTAssertEqual(merged?.sources, [.manual, .earnedTime], "sources must be unioned")
    }

    // MARK: 4b. Sweep: no lowercase twin — re-keys in place, preserving all other fields

    func test_sweep_noTwin_reKeysInPlace() {
        let idString = "D6510F2A-DBF0-4EF5-A21D-B4F78D3374CF"
        let upperKey = "savedList:\(idString)"
        let lowerKey = "savedList:\(idString.lowercased())"

        let upperRecord = makeRecord(
            recordKey: upperKey,
            tier: .savedList,
            targetKey: idString,
            sources: [.manual]
        )

        let dict: [String: ShieldRecord] = [upperKey: upperRecord]
        let swept = ScreenTimeRecordKeySweep.sweep(dict)

        XCTAssertEqual(swept.count, 1)
        let reKeyed = try? XCTUnwrap(swept[lowerKey])
        XCTAssertEqual(reKeyed?.recordKey, lowerKey)
        XCTAssertEqual(reKeyed?.sources, [.manual])
    }

    // MARK: 4c. Sweep: non-savedList keys and already-lowercase savedList keys are untouched

    func test_sweep_leavesOtherKeysAndAlreadyLowercaseUntouched() {
        let lowerKey = "savedList:d6510f2a-dbf0-4ef5-a21d-b4f78d3374cf"
        let exactAppKey = "exactApp:com.foo.Bar"

        let dict: [String: ShieldRecord] = [
            lowerKey: makeRecord(recordKey: lowerKey, tier: .savedList, targetKey: "d6510f2a-dbf0-4ef5-a21d-b4f78d3374cf", sources: [.manual]),
            exactAppKey: makeRecord(recordKey: exactAppKey, tier: .exactApp, targetKey: "com.foo.Bar", sources: [.limit])
        ]

        let swept = ScreenTimeRecordKeySweep.sweep(dict)

        XCTAssertEqual(swept.count, 2)
        XCTAssertEqual(swept[lowerKey]?.sources, [.manual])
        XCTAssertEqual(swept[exactAppKey]?.recordKey, exactAppKey, "non-savedList keys must be untouched, case included")
    }
}
