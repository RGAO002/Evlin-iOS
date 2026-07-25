import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import Evlin_iOS

final class AppLimitEpochStoreTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-limit-epoch-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("app-limit-epoch.json")
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try super.tearDownWithError()
    }

    func testEmptyStoreHasCurrentSchemaAndDoesNotCreateAFile() throws {
        let state = try makeStore().read()

        XCTAssertEqual(state.schemaVersion, AppLimitEpochStoreState.currentSchemaVersion)
        XCTAssertEqual(state.storeRevision, 0)
        XCTAssertNil(state.ownerChildDeviceID)
        XCTAssertTrue(state.slots.isEmpty)
        XCTAssertNil(state.legacyMigration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTransactionSurvivesRestartAndIncrementsRevision() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let store = makeStore(owner: owner)

        let accepted = try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.replaceSlotIfNewer(makeSetSlot(ruleID: ruleID, token: 7, source: .poll))
        }

        XCTAssertTrue(accepted)
        let restarted = try makeStore(owner: owner).read()
        XCTAssertEqual(restarted.storeRevision, 1)
        XCTAssertEqual(restarted.ownerChildDeviceID, owner)
        XCTAssertEqual(restarted.slots[ruleID]?.latestOrderingToken, 7)
        XCTAssertEqual(restarted.slots[ruleID]?.activeRule?.bundleID, "com.example.focus")
        XCTAssertEqual(restarted.lastMutationSource, .poll)
    }

    func testTransactionAcceptsByteExactReadbackWhenDateCanonicalizesByOneULP() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let commandID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let createdAt = Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: 4_740_046_264_882_201_161)
        )
        let store = makeStore(owner: owner)

        try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.slots[ruleID] = AppLimitVersionSlot(
                ruleID: ruleID,
                latestOrderingToken: 1,
                latestKind: .set,
                latestPayloadDigest: "set-1",
                activeRule: makeRule(id: ruleID),
                clearTombstone: nil,
                pendingOwnerWork: AppLimitOwnerWork(
                    workID: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    commandID: commandID,
                    ruleID: ruleID,
                    orderingToken: 1,
                    commandKind: .set,
                    payloadDigest: "set-1",
                    source: .poll,
                    createdAt: createdAt
                ),
                appliedReceipt: nil
            )
        }

        let persistedDate = try XCTUnwrap(
            makeStore(owner: owner).read().slots[ruleID]?.pendingOwnerWork?.createdAt
        )
        XCTAssertEqual(persistedDate.timeIntervalSince1970, createdAt.timeIntervalSince1970)
    }

    func testVersionSlotDecodesLegacyJSONWithoutAuthoritativeUsage() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let slot = makeSetSlot(ruleID: ruleID, token: 3, source: .poll)
        let encoded = try JSONEncoder().encode(slot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "authoritativeUsedTodayMinutes")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppLimitVersionSlot.self, from: legacyBytes)

        XCTAssertEqual(decoded.ruleID, ruleID)
        XCTAssertNil(decoded.authoritativeUsedTodayMinutes)
        XCTAssertFalse(decoded.isAuthoritativelyExhausted)
    }

    func testTransactionCannotClearBoundOwner() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000099")!
        let store = makeStore(owner: owner)

        _ = try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.ownerChildDeviceID = nil
            state.slots[ruleID] = makeSetSlot(ruleID: ruleID, token: 1, source: .poll)
        }

        XCTAssertEqual(try makeStore(owner: owner).read().ownerChildDeviceID, owner)
    }

    func testBoundRootRejectsNilExpectedOwnerWithoutChangingBytes() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000098")!
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000098")!
        let store = makeStore(owner: owner)
        _ = try store.transaction(source: .poll, expectedOwner: owner) { state in
            state.replaceSlotIfNewer(makeSetSlot(ruleID: ruleID, token: 1, source: .poll))
        }
        let boundBytes = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(
            try store.transaction(source: .wakeRecovery, expectedOwner: nil) { state in
                state.replaceSlotIfNewer(
                    makeSetSlot(ruleID: ruleID, token: 2, source: .wakeRecovery)
                )
            }
        ) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), boundBytes)
    }

    func testBoundRootRejectsLegacyMigrationWithoutCurrentOwner() throws {
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000097")!
        let existingRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000097")!
        _ = try makeStore(owner: owner).transaction(source: .poll, expectedOwner: owner) { state in
            state.replaceSlotIfNewer(
                makeSetSlot(ruleID: existingRuleID, token: 4, source: .poll)
            )
        }
        let boundBytes = try Data(contentsOf: fileURL)
        let suiteName = "app-limit-epoch-bound-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyRule = makeRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000096")!
        )
        defaults.set(
            try legacyEncoder().encode([legacyRule.id.uuidString: legacyRule]),
            forKey: AppLimitRuleStore.legacyRulesKey
        )

        XCTAssertThrowsError(try makeStore(legacyDefaults: defaults).read()) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), boundBytes)
        XCTAssertNotNil(defaults.data(forKey: AppLimitRuleStore.legacyRulesKey))
    }

    func testCorruptRootIsQuarantinedBeforeReturningEmptyState() throws {
        let corrupt = Data("not-json\n".utf8)
        try corrupt.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        let state = try makeStore(fileIO: fileIO).read()

        XCTAssertTrue(state.slots.isEmpty)
        XCTAssertEqual(fileIO.removedURLs, [fileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let digest = SHA256.hash(data: corrupt).map { String(format: "%02x", $0) }.joined()
        let quarantined = try XCTUnwrap(entries.first { $0.lastPathComponent.contains(".corrupt-\(digest).") })
        XCTAssertEqual(try Data(contentsOf: quarantined), corrupt)
    }

    func testInvariantInvalidRootIsQuarantinedBeforeReturningEmptyState() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000095")!
        let invalid = AppLimitEpochStoreState(
            storeRevision: 4,
            slots: [
                ruleID: AppLimitVersionSlot(
                    ruleID: ruleID,
                    latestOrderingToken: 3,
                    latestKind: .set,
                    latestPayloadDigest: "invalid-set",
                    activeRule: nil,
                    clearTombstone: nil,
                    pendingOwnerWork: nil,
                    appliedReceipt: nil
                ),
            ]
        )
        let corrupt = try stateEncoder().encode(invalid)
        try corrupt.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        let state = try makeStore(fileIO: fileIO).read()

        XCTAssertTrue(state.slots.isEmpty)
        XCTAssertEqual(fileIO.removedURLs, [fileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let digest = sha256(corrupt)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let quarantined = try XCTUnwrap(
            entries.first { $0.lastPathComponent.contains(".corrupt-\(digest).") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantined), corrupt)
    }

    func testBoundInvariantInvalidRootRejectsNilOwnerWithoutQuarantine() throws {
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000093")!
        let invalidBytes = try boundInvariantInvalidBytes(owner: owner)
        try invalidBytes.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        XCTAssertThrowsError(
            try makeStore(fileIO: fileIO, owner: owner).transaction(
                source: .poll,
                expectedOwner: nil
            ) { _ in
                XCTFail("unauthorized mutation must not run")
            }
        ) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), invalidBytes)
        XCTAssertTrue(fileIO.removedURLs.isEmpty)
        XCTAssertTrue(try quarantineURLs().isEmpty)
    }

    func testBoundInvariantInvalidRootRejectsWrongOwnerWithoutQuarantine() throws {
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000093")!
        let wrongOwner = UUID(uuidString: "20000000-0000-0000-0000-000000000092")!
        let invalidBytes = try boundInvariantInvalidBytes(owner: owner)
        try invalidBytes.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        XCTAssertThrowsError(
            try makeStore(fileIO: fileIO, owner: wrongOwner).transaction(
                source: .poll,
                expectedOwner: wrongOwner
            ) { _ in
                XCTFail("unauthorized mutation must not run")
            }
        ) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), invalidBytes)
        XCTAssertTrue(fileIO.removedURLs.isEmpty)
        XCTAssertTrue(try quarantineURLs().isEmpty)
    }

    func testBoundInvariantInvalidRootQuarantinesForCurrentOwner() throws {
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000093")!
        let invalidBytes = try boundInvariantInvalidBytes(owner: owner)
        try invalidBytes.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        let state = try makeStore(fileIO: fileIO, owner: owner).read()

        XCTAssertEqual(state, AppLimitEpochStoreState())
        XCTAssertEqual(fileIO.removedURLs, [fileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let quarantined = try XCTUnwrap(quarantineURLs().first)
        XCTAssertEqual(try Data(contentsOf: quarantined), invalidBytes)
    }

    func testUnsupportedFutureSchemaIsNotQuarantined() throws {
        let future = AppLimitEpochStoreState(
            schemaVersion: AppLimitEpochStoreState.currentSchemaVersion + 1,
            storeRevision: 7
        )
        let futureBytes = try stateEncoder().encode(future)
        try futureBytes.write(to: fileURL)
        let fileIO = RecordingDurableFileIO()

        XCTAssertThrowsError(try makeStore(fileIO: fileIO).read()) { error in
            XCTAssertEqual(
                error as? AppLimitEpochStoreError,
                .unsupportedSchema(AppLimitEpochStoreState.currentSchemaVersion + 1)
            )
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), futureBytes)
        XCTAssertTrue(fileIO.removedURLs.isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(entries.contains { $0.lastPathComponent.contains(".corrupt-") })
    }

    func testInterruptedReplacementRestoresPriorCanonicalBytes() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let store = makeStore()
        _ = try store.transaction(source: .poll, expectedOwner: nil) { state in
            state.replaceSlotIfNewer(makeSetSlot(ruleID: ruleID, token: 1, source: .poll))
        }
        let priorBytes = try Data(contentsOf: fileURL)
        let failingIO = FailAfterReplacingFileIO()
        failingIO.failNextWrite = true
        let interrupted = makeStore(fileIO: failingIO)

        XCTAssertThrowsError(
            try interrupted.transaction(source: .notificationServiceExtension, expectedOwner: nil) { state in
                state.replaceSlotIfNewer(
                    makeSetSlot(
                        ruleID: ruleID,
                        token: 2,
                        source: .notificationServiceExtension
                    )
                )
            }
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), priorBytes)
        XCTAssertEqual(try makeStore().read().slots[ruleID]?.latestOrderingToken, 1)
    }

    func testInterruptedFirstWriteUsesDurableDeletionAndLeavesNoRoot() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000094")!
        let fileIO = FailAfterReplacingDurableFileIO()
        fileIO.failNextWrite = true
        let store = makeStore(fileIO: fileIO)

        XCTAssertThrowsError(
            try store.transaction(source: .poll, expectedOwner: nil) { state in
                state.replaceSlotIfNewer(
                    makeSetSlot(ruleID: ruleID, token: 1, source: .poll)
                )
            }
        )

        XCTAssertEqual(fileIO.removedURLs, [fileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDurableRemoveUnlinksAndSynchronizesParentDirectory() throws {
        try Data("root".utf8).write(to: fileURL)
        let syncRecorder = DirectorySyncRecorder()
        let fileIO = DurableAppLimitEpochFileIO(
            syncDirectory: { syncRecorder.record($0) }
        )

        try fileIO.remove(at: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(syncRecorder.urls, [directoryURL])

        try fileIO.remove(at: fileURL)
        XCTAssertEqual(syncRecorder.urls, [directoryURL])
    }

    func testDirectorySyncFailureDuringFirstWriteReportsRestorationFailure() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000091")!
        let syncFailure = FailingDirectorySync()
        let fileIO = DurableAppLimitEpochFileIO(
            syncDirectory: { try syncFailure.sync($0) }
        )

        XCTAssertThrowsError(
            try makeStore(fileIO: fileIO).transaction(
                source: .poll,
                expectedOwner: nil
            ) { state in
                state.replaceSlotIfNewer(
                    makeSetSlot(ruleID: ruleID, token: 1, source: .poll)
                )
            }
        ) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .restorationFailed)
        }

        XCTAssertEqual(syncFailure.urls, [directoryURL, directoryURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testConcurrentAppAndNSEWritersDoNotLoseEitherSlot() throws {
        let appRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let nseRuleID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "app-limit-epoch-writers", attributes: .concurrent)
        let errors = LockedErrors()

        for (ruleID, source) in [
            (appRuleID, AppLimitCommandSource.poll),
            (nseRuleID, AppLimitCommandSource.notificationServiceExtension),
        ] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try self.makeStore().transaction(source: source, expectedOwner: nil) { state in
                        state.replaceSlotIfNewer(self.makeSetSlot(ruleID: ruleID, token: 1, source: source))
                    }
                } catch {
                    errors.append(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.values.isEmpty, "unexpected transaction errors: \(errors.values)")
        let state = try makeStore().read()
        XCTAssertEqual(state.storeRevision, 2)
        XCTAssertEqual(Set(state.slots.keys), [appRuleID, nseRuleID])
    }

    func testClearTombstoneSurvivesRestartAndRejectsLowerToken() throws {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let store = makeStore()
        _ = try store.transaction(source: .poll, expectedOwner: nil) { state in
            state.replaceSlotIfNewer(makeSetSlot(ruleID: ruleID, token: 2, source: .poll))
        }
        _ = try store.transaction(source: .notificationServiceExtension, expectedOwner: nil) { state in
            state.replaceSlotIfNewer(makeClearSlot(ruleID: ruleID, token: 3))
        }

        let restarted = makeStore()
        let beforeStaleWrite = try Data(contentsOf: fileURL)
        let accepted = try restarted.transaction(source: .wakeRecovery, expectedOwner: nil) { state in
            state.replaceSlotIfNewer(makeSetSlot(ruleID: ruleID, token: 2, source: .wakeRecovery))
        }
        let state = try restarted.read()

        XCTAssertFalse(accepted)
        XCTAssertEqual(try Data(contentsOf: fileURL), beforeStaleWrite)
        XCTAssertEqual(state.storeRevision, 2)
        XCTAssertEqual(state.slots[ruleID]?.latestOrderingToken, 3)
        XCTAssertEqual(state.slots[ruleID]?.latestKind, .clear)
        XCTAssertNil(state.slots[ruleID]?.activeRule)
        XCTAssertEqual(state.slots[ruleID]?.clearTombstone?.orderingToken, 3)
    }

    func testCompatibilityRemoveAllPreservesVersionedSlotsAndTombstones() throws {
        let legacyID = UUID(uuidString: "10000000-0000-0000-0000-000000000040")!
        let versionedID = UUID(uuidString: "10000000-0000-0000-0000-000000000041")!
        let clearedID = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!
        let store = makeStore()
        _ = try store.transaction(source: .poll, expectedOwner: nil) { state in
            state.slots[legacyID] = makeSetSlot(ruleID: legacyID, token: 0, source: .poll)
            state.slots[versionedID] = makeSetSlot(
                ruleID: versionedID,
                token: 8,
                source: .poll
            )
            state.slots[clearedID] = makeClearSlot(ruleID: clearedID, token: 9)
        }
        let facade = AppLimitRuleStore(
            epochStore: store,
            expectedOwnerProvider: { nil }
        )

        facade.removeAll()

        let state = try store.read()
        XCTAssertEqual(state.storeRevision, 2)
        XCTAssertNil(state.slots[legacyID])
        XCTAssertEqual(state.slots[versionedID]?.latestOrderingToken, 8)
        XCTAssertNotNil(state.slots[versionedID]?.activeRule)
        XCTAssertEqual(state.slots[clearedID]?.latestOrderingToken, 9)
        XCTAssertNotNil(state.slots[clearedID]?.clearTombstone)
    }

    func testIdentityTeardownResetRequiresOwnerAndUsesDurableRemoval() throws {
        let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000040")!
        let wrongOwner = UUID(uuidString: "20000000-0000-0000-0000-000000000041")!
        let fileIO = RecordingDurableFileIO()
        let store = makeStore(fileIO: fileIO, owner: owner)
        _ = try store.transaction(source: .poll, expectedOwner: owner) { _ in }
        let boundBytes = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try store.resetForIdentityTeardown(expectedOwner: wrongOwner)) { error in
            XCTAssertEqual(error as? AppLimitEpochStoreError, .ownerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), boundBytes)
        XCTAssertTrue(fileIO.removedURLs.isEmpty)

        try store.resetForIdentityTeardown(expectedOwner: owner)

        XCTAssertEqual(fileIO.removedURLs, [fileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try fileIO.remove(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testIdentityTeardownRequiresOwnerForLastMutationSourceOnlyRoot() throws {
        let state = AppLimitEpochStoreState(lastMutationSource: .poll)
        let bytes = try stateEncoder().encode(state)
        try bytes.write(to: fileURL)

        XCTAssertTrue(try makeStore().requiresOwnerForIdentityTeardown())
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testCanonicalBytesAreIndependentOfDictionaryInsertionOrder() throws {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000020")!
        let firstURL = directoryURL.appendingPathComponent("first.json")
        let secondURL = directoryURL.appendingPathComponent("second.json")
        let firstStore = makeStore(fileURL: firstURL)
        let secondStore = makeStore(fileURL: secondURL)

        _ = try firstStore.transaction(source: .poll, expectedOwner: nil) { state in
            state.slots[firstID] = makeSetSlot(ruleID: firstID, token: 1, source: .poll)
            state.slots[secondID] = makeSetSlot(ruleID: secondID, token: 2, source: .poll)
        }
        _ = try secondStore.transaction(source: .poll, expectedOwner: nil) { state in
            state.slots[secondID] = makeSetSlot(ruleID: secondID, token: 2, source: .poll)
            state.slots[firstID] = makeSetSlot(ruleID: firstID, token: 1, source: .poll)
        }

        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
    }

    func testLegacyUserDefaultsMigratesExactlyOnceWithDigestAudit() throws {
        let suiteName = "app-limit-epoch-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalRule = makeRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000030")!,
            bundleID: "com.example.legacy"
        )
        let legacyBytes = try legacyEncoder().encode([originalRule.id.uuidString: originalRule])
        defaults.set(legacyBytes, forKey: AppLimitRuleStore.legacyRulesKey)
        let store = makeStore(legacyDefaults: defaults)

        let migrated = try store.read()

        XCTAssertEqual(migrated.storeRevision, 1)
        XCTAssertEqual(migrated.slots[originalRule.id]?.activeRule, originalRule)
        XCTAssertEqual(migrated.slots[originalRule.id]?.latestOrderingToken, 0)
        XCTAssertEqual(migrated.legacyMigration?.payloadSHA256, sha256(legacyBytes))
        XCTAssertEqual(migrated.legacyMigration?.payloadByteCount, legacyBytes.count)
        XCTAssertEqual(migrated.legacyMigration?.migratedRuleCount, 1)
        XCTAssertNil(defaults.data(forKey: AppLimitRuleStore.legacyRulesKey))

        let replayRule = makeRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000031")!,
            bundleID: "com.example.replay"
        )
        defaults.set(
            try legacyEncoder().encode([replayRule.id.uuidString: replayRule]),
            forKey: AppLimitRuleStore.legacyRulesKey
        )

        let restarted = try makeStore(legacyDefaults: defaults).read()
        XCTAssertEqual(restarted.storeRevision, 1)
        XCTAssertNotNil(restarted.slots[originalRule.id])
        XCTAssertNil(restarted.slots[replayRule.id])
        XCTAssertEqual(restarted.legacyMigration, migrated.legacyMigration)
        XCTAssertNil(defaults.data(forKey: AppLimitRuleStore.legacyRulesKey))
    }

    private func makeStore(
        fileURL: URL? = nil,
        fileIO: any DeviceEpochFileIO = DurableAppLimitEpochFileIO(),
        owner: UUID? = nil,
        legacyDefaults: UserDefaults? = nil
    ) -> AppLimitEpochStore {
        AppLimitEpochStore(
            fileURL: fileURL ?? self.fileURL,
            lock: ActiveLockPersistenceLock.shared,
            fileIO: fileIO,
            ownerProvider: { owner },
            legacyDefaults: legacyDefaults
        )
    }

    private func makeSetSlot(
        ruleID: UUID,
        token: Int64,
        source: AppLimitCommandSource
    ) -> AppLimitVersionSlot {
        let commandID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        return AppLimitVersionSlot(
            ruleID: ruleID,
            latestOrderingToken: token,
            latestKind: .set,
            latestPayloadDigest: "set-\(token)",
            activeRule: makeRule(id: ruleID),
            clearTombstone: nil,
            pendingOwnerWork: AppLimitOwnerWork(
                workID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                commandID: commandID,
                ruleID: ruleID,
                orderingToken: token,
                commandKind: .set,
                payloadDigest: "set-\(token)",
                source: source,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            appliedReceipt: nil
        )
    }

    private func makeClearSlot(ruleID: UUID, token: Int64) -> AppLimitVersionSlot {
        AppLimitVersionSlot(
            ruleID: ruleID,
            latestOrderingToken: token,
            latestKind: .clear,
            latestPayloadDigest: "clear-\(token)",
            activeRule: nil,
            clearTombstone: AppLimitClearTombstone(
                ruleID: ruleID,
                orderingToken: token,
                payloadDigest: "clear-\(token)",
                source: .notificationServiceExtension,
                clearedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            pendingOwnerWork: AppLimitOwnerWork(
                workID: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                commandID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                ruleID: ruleID,
                orderingToken: token,
                commandKind: .clear,
                payloadDigest: "clear-\(token)",
                source: .notificationServiceExtension,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            appliedReceipt: nil
        )
    }

    private func makeRule(
        id: UUID,
        bundleID: String = "com.example.focus"
    ) -> AppLimitRule {
        AppLimitRule(
            id: id,
            appTokens: [],
            bundleID: bundleID,
            displayName: "Focus",
            budgetMinutes: 30,
            window: AppLimitWindow(
                startMinute: 0,
                endMinute: 1439,
                repeats: true,
                timezone: "America/New_York"
            ),
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil
        )
    }

    private func legacyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func stateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func boundInvariantInvalidBytes(owner: UUID) throws -> Data {
        let ruleID = UUID(uuidString: "10000000-0000-0000-0000-000000000093")!
        let state = AppLimitEpochStoreState(
            storeRevision: 4,
            ownerChildDeviceID: owner,
            slots: [
                ruleID: AppLimitVersionSlot(
                    ruleID: ruleID,
                    latestOrderingToken: 3,
                    latestKind: .set,
                    latestPayloadDigest: "invalid-set",
                    activeRule: nil,
                    clearTombstone: nil,
                    pendingOwnerWork: nil,
                    appliedReceipt: nil
                ),
            ]
        )
        return try stateEncoder().encode(state)
    }

    private func quarantineURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FailAfterReplacingFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let backing = SystemDeviceEpochFileIO()
    private let lock = NSLock()
    var failNextWrite = false

    func read(from url: URL) throws -> Data? {
        try backing.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try backing.writeAtomically(data, to: url)
        lock.lock()
        let shouldFail = failNextWrite
        failNextWrite = false
        lock.unlock()
        if shouldFail {
            throw TestFileIOError.interruptedAfterReplacement
        }
    }

    func remove(at url: URL) throws {
        try backing.remove(at: url)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}

private final class RecordingDurableFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let backing = DurableAppLimitEpochFileIO()
    private(set) var removedURLs: [URL] = []

    func read(from url: URL) throws -> Data? {
        try backing.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try backing.writeAtomically(data, to: url)
    }

    func remove(at url: URL) throws {
        removedURLs.append(url)
        try backing.remove(at: url)
    }
}

private final class FailAfterReplacingDurableFileIO: DeviceEpochFileIO, @unchecked Sendable {
    private let backing = DurableAppLimitEpochFileIO()
    private(set) var removedURLs: [URL] = []
    var failNextWrite = false

    func read(from url: URL) throws -> Data? {
        try backing.read(from: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try backing.writeAtomically(data, to: url)
        if failNextWrite {
            failNextWrite = false
            throw TestFileIOError.interruptedAfterReplacement
        }
    }

    func remove(at url: URL) throws {
        removedURLs.append(url)
        try backing.remove(at: url)
    }
}

private final class DirectorySyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}

private final class FailingDirectorySync: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func sync(_ url: URL) throws {
        lock.lock()
        storage.append(url)
        lock.unlock()
        throw TestFileIOError.directorySyncFailed
    }
}

private enum TestFileIOError: Error {
    case directorySyncFailed
    case interruptedAfterReplacement
}
