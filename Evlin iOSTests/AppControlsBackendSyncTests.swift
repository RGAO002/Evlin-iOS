import FamilyControls
import ManagedSettings
import XCTest
@testable import Evlin_iOS

@MainActor
final class AppControlsBackendSyncTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalAliasStore.shared.removeAllAliases()
        DefaultLockGroupStore.save(FamilyActivitySelection())
        AppControlsBackendSync.matchedCatalogUploadOverride = nil
    }

    override func tearDown() {
        AppControlsBackendSync.matchedCatalogUploadOverride = nil
        DefaultLockGroupStore.save(FamilyActivitySelection())
        LocalAliasStore.shared.removeAllAliases()
        super.tearDown()
    }

    func testRepairedDeviceRepublishesRetainedMatchedAppAndConfirmsNewIdentity() async throws {
        let syntheticTokenData = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8="
        let tokenJSON = #"{"data":"\#(syntheticTokenData)"}"#
        let token = try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data(tokenJSON.utf8)
        )
        let oldDeviceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let newDeviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let oldCatalogID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let newCatalogID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        var selection = FamilyActivitySelection()
        selection.applicationTokens.insert(token)
        DefaultLockGroupStore.save(selection)
        LocalAliasStore.shared.saveApplicationAliases(
            token: token,
            displayName: "Instagram",
            bundleIdentifier: "com.burbn.instagram",
            catalogAliasKey: oldCatalogID,
            catalogChildDeviceID: oldDeviceID
        )

        var capturedUploads: [ChildAppCatalogUploadApp] = []
        AppControlsBackendSync.matchedCatalogUploadOverride = { deviceID, uploads in
            XCTAssertEqual(deviceID, newDeviceID)
            capturedUploads = uploads
            return ChildAppCatalogUploadResponse(
                childDeviceID: newDeviceID,
                count: 1,
                apps: [
                    ChildAppCatalogEntryResponse(
                        id: newCatalogID,
                        displayName: "Instagram",
                        tokenKind: "app",
                        bundleID: "com.burbn.instagram",
                        aliases: ["instagram", "com.burbn.instagram"],
                        tokenAvailable: true,
                        tokenDataBase64: uploads.first?.tokenDataBase64,
                        updatedAt: nil
                    ),
                ]
            )
        }

        let succeeded = await AppControlsBackendSync
            .republishMatchedCatalogIfNeeded(for: newDeviceID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(capturedUploads.count, 1)
        XCTAssertNil(capturedUploads.first?.aliasKey)
        XCTAssertEqual(capturedUploads.first?.sourceDeviceID, newDeviceID)
        XCTAssertTrue(LocalAliasStore.shared.hasCatalogConfirmation(
            forApplicationToken: token,
            childDeviceID: newDeviceID
        ))
        XCTAssertFalse(LocalAliasStore.shared.hasCatalogConfirmation(
            forApplicationToken: token,
            childDeviceID: oldDeviceID
        ))
    }

    func testPollSynchronizationRetriesBothRetainedAppControlChannels() async {
        let deviceID = UUID()
        var calls: [String] = []

        let result = await AppControlsBackendSync.synchronizeRetainedAppControls(
            for: deviceID,
            publishLockGroup: { receivedDeviceID in
                XCTAssertEqual(receivedDeviceID, deviceID)
                calls.append("list")
                return true
            },
            publishMatchedCatalog: { receivedDeviceID in
                XCTAssertEqual(receivedDeviceID, deviceID)
                calls.append("catalog")
                return false
            }
        )

        XCTAssertEqual(calls, ["list", "catalog"])
        XCTAssertFalse(result)
    }

    func testExplicitFinalSetupBypassesRecentUploadCooldown() {
        let deviceID = UUID()
        let now = Date()
        let signature = "selection-signature"

        XCTAssertFalse(AppControlsBackendSync.needsLockGroupUpload(
            force: false,
            deviceID: deviceID,
            selectionSignature: signature,
            lockedSetAliasKey: UUID(),
            publishedDeviceID: deviceID,
            publishedSignature: signature
        ))
        XCTAssertTrue(AppControlsBackendSync.needsLockGroupUpload(
            force: true,
            deviceID: deviceID,
            selectionSignature: signature,
            lockedSetAliasKey: UUID(),
            publishedDeviceID: deviceID,
            publishedSignature: signature
        ))

        XCTAssertTrue(AppControlsBackendSync.shouldThrottleLockGroupUpload(
            force: false,
            deviceID: deviceID,
            lastAttemptDeviceID: deviceID,
            lastAttemptAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertFalse(AppControlsBackendSync.shouldThrottleLockGroupUpload(
            force: true,
            deviceID: deviceID,
            lastAttemptDeviceID: deviceID,
            lastAttemptAt: now.addingTimeInterval(-5),
            now: now
        ))
    }

    func testMatchedCatalogReconciliationPublishesEmptySnapshotToDeleteStaleRows() async {
        let deviceID = UUID()
        var captured: [ChildAppCatalogUploadApp]?
        AppControlsBackendSync.matchedCatalogUploadOverride = { receivedDeviceID, uploads in
            XCTAssertEqual(receivedDeviceID, deviceID)
            captured = uploads
            return ChildAppCatalogUploadResponse(
                childDeviceID: deviceID,
                count: 0,
                apps: []
            )
        }

        let succeeded = await AppControlsBackendSync
            .republishMatchedCatalogIfNeeded(for: deviceID, forceSnapshot: true)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(captured, [], "An empty local match set must clear stale backend rows")
    }

    func testMatchedCatalogReconciliationIncludesAlreadyConfirmedRowsInSnapshot() async throws {
        let token = try syntheticApplicationToken(byte: 7)
        let deviceID = UUID()
        let catalogID = UUID()
        var selection = FamilyActivitySelection()
        selection.applicationTokens.insert(token)
        DefaultLockGroupStore.save(selection)
        LocalAliasStore.shared.saveApplicationAliases(
            token: token,
            displayName: "Duolingo",
            bundleIdentifier: "com.duolingo.DuolingoMobile",
            catalogAliasKey: catalogID,
            catalogChildDeviceID: deviceID
        )

        var captured: [ChildAppCatalogUploadApp]?
        AppControlsBackendSync.matchedCatalogUploadOverride = { receivedDeviceID, uploads in
            XCTAssertEqual(receivedDeviceID, deviceID)
            captured = uploads
            return ChildAppCatalogUploadResponse(
                childDeviceID: deviceID,
                count: 1,
                apps: [
                    ChildAppCatalogEntryResponse(
                        id: catalogID,
                        displayName: uploads.first?.displayName ?? "Duolingo",
                        tokenKind: "app",
                        bundleID: uploads.first?.bundleID,
                        aliases: ["duolingo", "com.duolingo.duolingomobile"],
                        tokenAvailable: true,
                        tokenDataBase64: uploads.first?.tokenDataBase64,
                        updatedAt: nil
                    ),
                ]
            )
        }

        let succeeded = await AppControlsBackendSync
            .republishMatchedCatalogIfNeeded(for: deviceID, forceSnapshot: true)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(captured?.map(\.displayName), ["Duolingo"])
    }

    func testCatalogConfirmationNotifiesVisibleAppControlsForCurrentDevice() async throws {
        let token = try syntheticApplicationToken(byte: 9)
        let deviceID = UUID()
        let notification = expectation(
            forNotification: .evlinCatalogConfirmationChanged,
            object: nil
        ) { note in
            (note.object as? UUID) == deviceID
        }

        LocalAliasStore.shared.saveApplicationAliases(
            token: token,
            displayName: "YouTube",
            bundleIdentifier: "com.google.ios.youtube",
            catalogAliasKey: UUID(),
            catalogChildDeviceID: deviceID
        )

        await fulfillment(of: [notification], timeout: 0.2)
    }

    private func syntheticApplicationToken(byte: UInt8) throws -> ApplicationToken {
        let data = Data(repeating: byte, count: 128).base64EncodedString()
        return try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data(#"{"data":"\#(data)"}"#.utf8)
        )
    }
}
